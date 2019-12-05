{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Database.Beam.Migrate.Postgres
  ( getSchema
  )
where

import           Data.String
import           Control.Monad.State
import           Control.Applicative
import           Data.Maybe                               ( fromMaybe )
import           Data.Bits                                ( (.&.)
                                                          , shiftR
                                                          )
import           Data.Foldable                            ( foldlM )
import qualified Data.Vector                             as V
import qualified Data.Map.Strict                         as M
import qualified Data.Set                                as S
import           Data.Map                                 ( Map )
import           Data.Set                                 ( Set )
import           Data.Text                                ( Text )
import qualified Data.Text.Encoding                      as TE
import qualified Data.Text                               as T
import           Data.ByteString                          ( ByteString )

import           Database.Beam.Backend.SQL         hiding ( tableName )
import qualified Database.PostgreSQL.Simple              as Pg
import           Database.PostgreSQL.Simple.FromRow       ( FromRow(..)
                                                          , field
                                                          )
import           Database.PostgreSQL.Simple.FromField     ( FromField(..)
                                                          , fromField
                                                          )
import qualified Database.PostgreSQL.Simple.Types        as Pg
import qualified Database.PostgreSQL.Simple.TypeInfo.Static
                                                         as Pg

import           Database.Beam.Migrate.Types

--
-- Necessary types to make working with the underlying raw SQL a bit more pleasant
--

data SqlRawOtherConstraintType = 
    SQL_raw_pk
  | SQL_raw_unique
  deriving (Show, Eq)

data SqlOtherConstraint = SqlOtherConstraint
    { sqlCon_table :: TableName
    , sqlCon_constraint_type :: SqlRawOtherConstraintType
    , sqlCon_fk_colums :: V.Vector ColumnName
    , sqlCon_name :: Text
    } deriving (Show, Eq)

instance Pg.FromRow SqlOtherConstraint where
  fromRow = SqlOtherConstraint <$> (fmap TableName field)
                               <*> field
                               <*> (fmap (V.map ColumnName) field) 
                               <*> field

data SqlForeignConstraint = SqlForeignConstraint
    { sqlFk_foreign_table   :: TableName
    , sqlFk_primary_table   :: TableName
    , sqlFk_fk_columns      :: V.Vector ColumnName
    -- ^ The columns in the /foreign/ table.
    , sqlFk_pk_columns      :: V.Vector ColumnName
    -- ^ The columns in the /current/ table.
    , sqlFk_name            :: Text
    } deriving (Show, Eq)

instance Pg.FromRow SqlForeignConstraint where
  fromRow = SqlForeignConstraint <$> (fmap TableName field)
                                 <*> (fmap TableName field) 
                                 <*> (fmap (V.map ColumnName) field) 
                                 <*> (fmap (V.map ColumnName) field) 
                                 <*> field

instance FromField TableName where
  fromField f dat = TableName <$> fromField f dat

instance FromField ColumnName where
  fromField f dat = ColumnName <$> fromField f dat

instance FromField SqlRawOtherConstraintType where
  fromField f dat = do
      t <- fromField f dat
      case t of
        "PRIMARY KEY" -> pure SQL_raw_pk
        "UNIQUE"      -> pure SQL_raw_unique
        _ -> fail ("Unexpected costraint type: " <> t)

--
-- Postgres queries to extract the schema out of the DB
--

-- | A SQL query to select all user's queries, skipping any beam-related tables (i.e. leftovers from
-- beam-migrate, for example).
userTablesQ :: Pg.Query
userTablesQ = fromString $ unlines
  [ "SELECT cl.oid, relname FROM pg_catalog.pg_class \"cl\" join pg_catalog.pg_namespace \"ns\" "
  , "on (ns.oid = relnamespace) where nspname = any (current_schemas(false)) and relkind='r' "
  , "and relname NOT LIKE 'beam_%'"
  ]

-- | Get information about default values for /all/ tables.
defaultsQ :: Pg.Query
defaultsQ = fromString $ unlines
  [ "SELECT col.table_name, col.column_name, col.column_default "
  , "FROM information_schema.columns col "
  , "WHERE col.column_default IS NOT NULL "
  , "AND col.table_schema NOT IN('information_schema', 'pg_catalog') "
  , "ORDER BY col.table_name"
  ]

-- | Get information about columns for this table. Due to the fact this is a query executed for /each/
-- table, is important this is as light as possible to keep the performance decent.
tableColumnsQ :: Pg.Query
tableColumnsQ = fromString $ unlines
  [ "SELECT attname, atttypid, atttypmod, attnotnull, pg_catalog.format_type(atttypid, atttypmod) "
  , "FROM pg_catalog.pg_attribute att "
  , "WHERE att.attrelid=? AND att.attnum>0 AND att.attisdropped='f' "
  ]

-- | Get the enumeration data for all enum types in the database.
enumerationsQ :: Pg.Query
enumerationsQ = fromString $ unlines
  [ "SELECT t.typname, t.oid, array_agg(e.enumlabel ORDER BY e.enumsortorder)"
  , "FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid"
  , "GROUP BY t.typname, t.oid" 
  ]

-- | Return all foreign key constraints for /all/ 'Table's.
foreignKeysQ :: Pg.Query
foreignKeysQ = fromString $ unlines
  [ "SELECT kcu.table_name as foreign_table,"
  , "       rel_kcu.table_name as primary_table,"
  , "       array_agg(kcu.column_name)::text[] as fk_columns,"
  , "       array_agg(rel_kcu.column_name)::text[] as pk_columns,"
  , "       kcu.constraint_name as cname"
  , "FROM information_schema.table_constraints tco"
  , "JOIN information_schema.key_column_usage kcu"
  , "          on tco.constraint_schema = kcu.constraint_schema"
  , "          and tco.constraint_name = kcu.constraint_name"
  , "JOIN information_schema.referential_constraints rco"
  , "          on tco.constraint_schema = rco.constraint_schema"
  , "          and tco.constraint_name = rco.constraint_name"
  , "JOIN information_schema.key_column_usage rel_kcu"
  , "          on rco.unique_constraint_schema = rel_kcu.constraint_schema"
  , "          and rco.unique_constraint_name = rel_kcu.constraint_name"
  , "          and kcu.ordinal_position = rel_kcu.ordinal_position"
  , "GROUP BY foreign_table, primary_table, cname"
  , "ORDER BY primary_table"
  ]

-- | Return /all other constraints that are not FKs/ (i.e. 'PRIMARY KEY', 'UNIQUE', etc) for all the tables.
otherConstraintsQ :: Pg.Query
otherConstraintsQ = fromString $ unlines
  [ "SELECT kcu.table_name as foreign_table,"
  , "       tco.constraint_type as ctype,"
  , "       array_agg(kcu.column_name)::text[] as fk_columns,"
  , "       kcu.constraint_name as cname"
  , "FROM information_schema.table_constraints tco"
  , "RIGHT JOIN information_schema.key_column_usage kcu"
  , "           on tco.constraint_schema = kcu.constraint_schema"
  , "           and tco.constraint_name = kcu.constraint_name"
  , "LEFT JOIN  information_schema.referential_constraints rco"
  , "           on tco.constraint_schema = rco.constraint_schema"
  , "           and tco.constraint_name = rco.constraint_name"
  , "LEFT JOIN  information_schema.key_column_usage rel_kcu"
  , "           on rco.unique_constraint_schema = rel_kcu.constraint_schema"
  , "           and rco.unique_constraint_name = rel_kcu.constraint_name"
  , "           and kcu.ordinal_position = rel_kcu.ordinal_position"
  , "WHERE tco.constraint_type = 'PRIMARY KEY' OR tco.constraint_type = 'UNIQUE'"
  , "GROUP BY foreign_table, ctype, cname"
  , "ORDER BY ctype"
  ]

-- | Return all \"action types\" for /all/ the constraints.
referenceActionsQ :: Pg.Query
referenceActionsQ = fromString $ unlines
  [ "SELECT c.conname, c. confdeltype, c.confupdtype FROM "
  , "(SELECT r.conrelid, r.confrelid, unnest(r.conkey) AS conkey, unnest(r.confkey) AS confkey, r.conname, r.confupdtype, r.confdeltype "
  , "FROM pg_catalog.pg_constraint r WHERE r.contype = 'f') AS c "
  , "INNER JOIN pg_attribute a_parent ON a_parent.attnum = c.confkey AND a_parent.attrelid = c.confrelid "
  , "INNER JOIN pg_class cl_parent ON cl_parent.oid = c.confrelid "
  , "INNER JOIN pg_namespace sch_parent ON sch_parent.oid = cl_parent.relnamespace "
  , "INNER JOIN pg_attribute a_child ON a_child.attnum = c.conkey AND a_child.attrelid = c.conrelid "
  , "INNER JOIN pg_class cl_child ON cl_child.oid = c.conrelid "
  , "INNER JOIN pg_namespace sch_child ON sch_child.oid = cl_child.relnamespace "
  , "WHERE sch_child.nspname = current_schema() ORDER BY c.conname "
  ]

-- | Connects to a running PostgreSQL database and extract the relevant 'Schema' out of it.
getSchema :: Pg.Connection -> IO Schema
getSchema conn = do
  allTableConstraints  <- getAllConstraints conn
  allDefaults          <- getAllDefaults conn
  enumerationData      <- Pg.fold_ conn enumerationsQ mempty getEnumeration
  tables               <-
      Pg.fold_ conn userTablesQ mempty (getTable allDefaults enumerationData allTableConstraints)
  pure $ Schema tables (M.fromList $ M.elems enumerationData)

  where
    getEnumeration :: Map Pg.Oid (EnumerationName, Enumeration) 
                   -> (Text, Pg.Oid, V.Vector Text) 
                   -> IO (Map Pg.Oid (EnumerationName, Enumeration))
    getEnumeration allEnums (enumName, oid, V.toList -> vals) =
      pure $ M.insert oid (EnumerationName enumName, (Enumeration vals)) allEnums

    getTable :: AllDefaults
             -> Map Pg.Oid (EnumerationName, Enumeration) 
             -> AllTableConstraints 
             -> Tables 
             -> (Pg.Oid, Text) 
             -> IO Tables
    getTable allDefaults enumData allTableConstraints allTables (oid, TableName -> tName) = do
      pgColumns <- Pg.query conn tableColumnsQ (Pg.Only oid)
      newTable  <-
        Table (fromMaybe noTableConstraints (M.lookup tName allTableConstraints))
          <$> foldlM (getColumns tName enumData allDefaults) mempty pgColumns
      pure $ M.insert tName newTable allTables

    getColumns :: TableName
               -> Map Pg.Oid (EnumerationName, Enumeration) 
               -> AllDefaults
               -> Columns 
               -> (ByteString, Pg.Oid, Int, Bool, ByteString) 
               -> IO Columns
    getColumns tName enumData defaultData c (attname, atttypid, atttypmod, attnotnull, format_type) = do
      let mbPrecision = if atttypmod == -1 then Nothing else Just (atttypmod - 4)
      case pgTypeToColumnType atttypid mbPrecision <|> pgEnumTypeToColumnType enumData atttypid of
        Just cType -> do
          let nullConstraint  = if attnotnull then S.fromList [NotNull] else mempty
          let columnName = ColumnName (TE.decodeUtf8 attname)
          let defaultConstraintMb = do
                x <- M.lookup tName defaultData
                y <- M.lookup columnName x
                pure $ S.singleton y
          let inferredConstraints = nullConstraint <> fromMaybe mempty defaultConstraintMb
          let newColumn  = Column cType inferredConstraints
          pure $ M.insert columnName newColumn c
        Nothing ->
          fail
            $  "Couldn't convert pgType "
            <> show format_type
            <> " of field "
            <> show attname
            <> " into a valid ColumnType."

--
-- Postgres type mapping
--

pgEnumTypeToColumnType :: Map Pg.Oid (EnumerationName, Enumeration) 
                       -> Pg.Oid 
                       -> Maybe ColumnType
pgEnumTypeToColumnType enumData oid = 
    (\(n, _) -> PgSpecificType (PgEnumeration n)) <$> M.lookup oid enumData

-- | Tries to convert from a Postgres' 'Oid' into 'ColumnType'.
-- Mostly taken from [beam-migrate](Database.Beam.Postgres.Migrate).
pgTypeToColumnType :: Pg.Oid -> Maybe Int -> Maybe ColumnType
pgTypeToColumnType oid width
  | Pg.typoid Pg.int2 == oid
  = Just (SqlStdType smallIntType)
  | Pg.typoid Pg.int4 == oid
  = Just (SqlStdType intType)
  | Pg.typoid Pg.int8 == oid
  = Just (SqlStdType bigIntType)
  | Pg.typoid Pg.bpchar == oid
  = Just (SqlStdType $ charType (fromIntegral <$> width) Nothing)
  | Pg.typoid Pg.varchar == oid
  = Just (SqlStdType $ varCharType (fromIntegral <$> width) Nothing)
  | Pg.typoid Pg.bit == oid
  = Just (SqlStdType $ bitType (fromIntegral <$> width))
  | Pg.typoid Pg.varbit == oid
  = Just (SqlStdType $ varBitType (fromIntegral <$> width))
  | Pg.typoid Pg.numeric == oid
  = let decimals = fromMaybe 0 width .&. 0xFFFF
        prec     = (fromMaybe 0 width `shiftR` 16) .&. 0xFFFF
    in  Just (SqlStdType $ numericType (Just (fromIntegral prec, Just (fromIntegral decimals))))
  | Pg.typoid Pg.float4 == oid
  = Just (SqlStdType $ floatType (fromIntegral <$> width))
  | Pg.typoid Pg.float8 == oid
  = Just (SqlStdType doubleType)
  | Pg.typoid Pg.date == oid
  = Just (SqlStdType dateType)
  | Pg.typoid Pg.text == oid
  = Just (SqlStdType characterLargeObjectType)
  | Pg.typoid Pg.bytea == oid
  = Just (SqlStdType binaryLargeObjectType)
  | Pg.typoid Pg.bool == oid
  = Just (SqlStdType booleanType)
  | Pg.typoid Pg.time == oid
  = Just (SqlStdType $ timeType Nothing False)
  | Pg.typoid Pg.timestamp == oid
  = Just (SqlStdType $timestampType Nothing False)
  | Pg.typoid Pg.timestamptz == oid
  = Just (SqlStdType $ timestampType Nothing True)
  | Pg.typoid Pg.json == oid
  -- json types
  = Just (PgSpecificType PgJson)
  | Pg.typoid Pg.jsonb == oid
  = Just (PgSpecificType PgJsonB)
  -- range types
  | Pg.typoid Pg.int4range == oid
  = Just (PgSpecificType PgRangeInt4)
  | Pg.typoid Pg.int8range == oid
  = Just (PgSpecificType PgRangeInt8)
  | Pg.typoid Pg.numrange == oid
  = Just (PgSpecificType PgRangeNum)
  | Pg.typoid Pg.tsrange == oid
  = Just (PgSpecificType PgRangeTs)
  | Pg.typoid Pg.tstzrange == oid
  = Just (PgSpecificType PgRangeTsTz)
  | Pg.typoid Pg.daterange == oid
  = Just (PgSpecificType PgRangeDate)
  | otherwise 
  = Nothing

--
-- Constraints discovery
--

type AllTableConstraints = Map TableName (Set TableConstraint)
type AllDefaults    = Map TableName Defaults
type Defaults       = Map ColumnName ColumnConstraint
type AllColumnConstraints = Map ColumnName (Set ColumnConstraint)

getAllDefaults :: Pg.Connection -> IO AllDefaults
getAllDefaults conn = Pg.fold_ conn defaultsQ mempty (\acc -> pure . addDefault acc)
  where
      addDefault :: AllDefaults -> (TableName, ColumnName, Text) -> AllDefaults
      addDefault m (tName, colName, defValue) =
          let entry = M.singleton colName (Default defValue)
          in M.alter (\case Nothing -> Just entry
                            Just ss -> Just $ ss <> entry
                     ) tName m

getAllConstraints :: Pg.Connection -> IO AllTableConstraints
getAllConstraints conn = do
    allActions <- mkActions <$> Pg.query_ conn referenceActionsQ
    allForeignKeys <- Pg.fold_ conn foreignKeysQ mempty (\acc -> pure . addFkConstraint allActions acc)
    Pg.fold_ conn otherConstraintsQ allForeignKeys (\acc -> pure . addOtherConstraint acc)
  where
      addFkConstraint :: ReferenceActions 
                      -> AllTableConstraints 
                      -> SqlForeignConstraint
                      -> AllTableConstraints
      addFkConstraint actions st SqlForeignConstraint{..} = flip execState st $ do
        let currentTable = sqlFk_foreign_table
        let columnSet = S.fromList $ zip (V.toList sqlFk_fk_columns) (V.toList sqlFk_pk_columns)
        -- Here we need to add two constraints: one for 'ForeignKey' and one for
        -- 'IsForeignKeyOf'.
        let (onDelete, onUpdate) = 
                case M.lookup sqlFk_name (getActions actions) of
                  Nothing -> (NoAction, NoAction)
                  Just a  -> (actionOnDelete a, actionOnUpdate a)
        addTableConstraint currentTable (ForeignKey sqlFk_name sqlFk_primary_table columnSet onDelete onUpdate)

      addOtherConstraint :: AllTableConstraints 
                         -> SqlOtherConstraint
                         -> AllTableConstraints
      addOtherConstraint st SqlOtherConstraint{..} = flip execState st $ do
          let currentTable = sqlCon_table
          let columnSet = S.fromList . V.toList $ sqlCon_fk_colums
          case sqlCon_constraint_type of
            SQL_raw_unique -> addTableConstraint currentTable (Unique sqlCon_name columnSet)
            SQL_raw_pk -> addTableConstraint currentTable (PrimaryKey sqlCon_name columnSet)


newtype ReferenceActions = ReferenceActions { getActions :: Map Text Actions }
newtype RefEntry = RefEntry { unRefEntry :: (Text, ReferenceAction, ReferenceAction) }

mkActions :: [RefEntry] -> ReferenceActions
mkActions = ReferenceActions . M.fromList . map ((\(a,b,c) -> (a, Actions b c)) . unRefEntry)

instance Pg.FromRow RefEntry where
  fromRow = fmap RefEntry ((,,) <$> field 
                                <*> (fmap mkAction field) 
                                <*> (fmap mkAction field))

data Actions = Actions {
    actionOnDelete :: ReferenceAction
  , actionOnUpdate :: ReferenceAction
  }


mkAction :: Text -> ReferenceAction
mkAction c = case c of
  "a" -> NoAction
  "r" -> Restrict
  "c" -> Cascade
  "n" -> SetNull
  "d" -> SetDefault
  _ -> error . T.unpack $ "unknown reference action type: " <> c


--
-- Useful combinators to add constraints for a column or table if already there.
--

addTableConstraint :: TableName
                   -> TableConstraint 
                   -> State AllTableConstraints ()
addTableConstraint tName cns =
  modify' (\tcon -> M.alter (\case Nothing -> Just $ S.singleton cns
                                   Just ss -> Just $ S.insert cns ss) tName tcon)
