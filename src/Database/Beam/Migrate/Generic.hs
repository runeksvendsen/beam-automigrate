{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}
module Database.Beam.Migrate.Generic where

import           Database.Beam.Migrate.Util     ( pkFieldNames )
import           Database.Beam.Migrate.Types
import           Data.Kind
import           Data.Proxy
import qualified Data.Map.Strict               as M
import qualified Data.Set                      as S
import           Lens.Micro                     ( (^.) )

import           GHC.Generics
import           GHC.TypeLits

import           Database.Beam.Schema           ( Beamable
                                                , PrimaryKey
                                                , TableEntity
                                                , TableSettings
                                                )
import qualified Database.Beam.Schema          as Beam
import           Database.Beam.Schema.Tables    ( IsDatabaseEntity
                                                , dbEntityDescriptor
                                                , dbEntityName
                                                , dbTableSettings
                                                , DatabaseEntity(..)
                                                )

import           Database.Beam.Migrate.Compat
import           Database.Beam.Migrate.Annotated

-- | To make kind signatures more readable.
type DatabaseKind = (Type -> Type) -> Type

-- | To make kind signatures more readable.
type TableKind    = (Type -> Type) -> Type

--
--- Machinery to derive a 'Schema' from a 'DatabaseSettings'.
--

class GSchema be db x where
    gSchema :: AnnotatedDatabaseSettings be db -> x p -> Schema

-- Table-specific classes

class GTables be db x where
    gTables :: AnnotatedDatabaseSettings be db -> x p -> Tables

class GTableEntry be db x where
    gTableEntry :: AnnotatedDatabaseSettings be db -> x p -> (TableName, Table)

class GTable be db x where
    gTable :: AnnotatedDatabaseSettings be db -> x p -> Table

-- Column-specific classes

class GColumns x where
    gColumns :: x p -> Columns

class GTableConstraintColumns be db x where
    gTableConstraintsColumns :: AnnotatedDatabaseSettings be db -> TableName -> x p -> S.Set TableConstraint

class GColumnEntry x where
    gColumnEntry :: x p -> (ColumnName, Column)

class GColumn x where
    gColumn :: x p -> Column

--
-- Deriving information about 'Schema's
--

instance GSchema be db x => GSchema be db (D1 f x) where
  gSchema db (M1 x) = gSchema db x

instance (Constructor f, GTables be db x) => GSchema be db (C1 f x) where
  gSchema db (M1 x) = Schema { schemaTables = gTables db x }

--
-- Deriving information about 'Table's.
--

instance GTableEntry be db (S1 f x) => GTables be db (S1 f x) where
  gTables db = uncurry M.singleton . gTableEntry db

instance GTableEntry be db x => GTableEntry be db (S1 f x) where
  gTableEntry db (M1 x) = gTableEntry db x

instance (GTables be db a, GTables be db b) => GTables be db (a :*: b) where
  gTables db (a :*: b) = gTables db a <> gTables db b

instance ( IsAnnotatedDatabaseEntity be (TableEntity tbl)
         , GColumns (Rep (TableSchema tbl))
         , Generic (TableSchema tbl)
         , Beam.Table tbl
         , GTableConstraintColumns be db (Rep (TableSchema tbl))
         )
  => GTableEntry be db (K1 R (AnnotatedDatabaseEntity be' db' (TableEntity tbl))) where
  gTableEntry db (K1 annEntity) =
    let entity = annEntity ^. deannotate
        tName = entity ^. dbEntityDescriptor . dbEntityName
        pks   = S.singleton (PrimaryKey (tName <> "_pkey") (S.fromList $ pkFieldNames entity))
        columns = gColumns . from $ (dbAnnotatedSchema (annEntity ^. annotatedDescriptor))
        annotatedCons  = dbAnnotatedConstraints (annEntity ^. annotatedDescriptor)
        discoveredCons = gTableConstraintsColumns db (TableName tName) . from $ (dbAnnotatedSchema (annEntity ^. annotatedDescriptor))
    in  (TableName tName, Table (pks <> annotatedCons <> discoveredCons) columns)

instance GColumns x => GColumns (D1 f x) where
  gColumns (M1 x) = gColumns x

instance GTableConstraintColumns be db x => GTableConstraintColumns be db (D1 f x) where
  gTableConstraintsColumns db tbl (M1 x) = gTableConstraintsColumns db tbl x

instance GColumns x => GColumns (C1 f x) where
  gColumns (M1 x) = gColumns x

instance GTableConstraintColumns be db x => GTableConstraintColumns be db (C1 f x) where
  gTableConstraintsColumns db tbl (M1 x) = gTableConstraintsColumns db tbl x

instance (GColumns a, GColumns b) => GColumns (a :*: b) where
  gColumns (a :*: b) = gColumns a <> gColumns b

instance (GTableConstraintColumns be db a, GTableConstraintColumns be db b) => GTableConstraintColumns be db (a :*: b) where
  gTableConstraintsColumns db tbl (a :*: b) = S.union (gTableConstraintsColumns db tbl a) (gTableConstraintsColumns db tbl b)


--
-- Column entries
--

instance GColumns (S1 m (K1 R (TableFieldSchema tbl ty))) where
  gColumns (M1 (K1 (TableFieldSchema name (FieldSchema ty constr)))) =
    M.singleton (ColumnName name) (Column ty constr)

instance ( GColumns (Rep (PrimaryKey tbl f))
         , Generic (PrimaryKey tbl f)
         , Beamable (PrimaryKey tbl)
         )
    => GColumns (S1 m (K1 R (PrimaryKey tbl f))) where
  gColumns (M1 (K1 e)) = gColumns (from e)

instance GTableConstraintColumns be db (S1 m (K1 R (TableFieldSchema tbl ty))) where
  gTableConstraintsColumns _db _tbl (M1 (K1 _)) = S.empty

instance ( Generic (AnnotatedDatabaseSettings be db)
         , Generic (PrimaryKey tbl f)
         , GColumns (Rep (PrimaryKey tbl f))
         , GTableLookupSettings sel tbl (Rep (AnnotatedDatabaseSettings be db))
         , m ~ MetaSel sel su ss ds
         ) => GTableConstraintColumns be db (S1 m (K1 R (PrimaryKey tbl f))) where
  gTableConstraintsColumns db (TableName tname) (M1 (K1 e)) =
    case cnames of
      [] -> S.empty -- TODO: if for whatever reason we have no columns in our key, we don't generate a constraint
      ColumnName cname : _ ->
        S.singleton
          (ForeignKey
            (tname <> "_" <> cname <> "_fkey")
            reftname
            (S.fromList (zip cnames refcnames))
            NoAction -- TODO: what should the default be?
            NoAction -- TODO: what should the default be?
          )
    where
      cnames :: [ColumnName]
      cnames = M.keys (gColumns (from e))

      reftname :: TableName
      refcnames :: [ColumnName]
      (reftname, refcnames) = gTableLookupSettings (Proxy @sel) (Proxy @tbl) (from db)

-- We want a type class for the table lookup, because we want to return a
-- value-level table name based on the database settings!

-- | Lookup a table by type in the given DB settings.
--
-- The selector name is only provided for error messages.
--
-- Only returns if the table type is unique.
-- Returns the table name and the column names of its primary key.
--
class GTableLookupSettings (sel :: Maybe Symbol) (tbl :: TableKind) x where
  gTableLookupSettings :: Proxy sel -> Proxy tbl -> x p -> (TableName, [ColumnName])

-- | Helper class that takes an additional continuation parameter 'k'.
--
-- We treat 'k' as a type-level stack with 'U1' being the empty stack and
-- ':*:' used right-associatively to place items onto the stack.
--
-- The reason we do not use a type-level list here is that we also need
-- a term-level representation of the continuation, and we already have
-- suitable inhabitants for 'U1' and ':*:'.
--
class GTableLookupTables (sel :: Maybe Symbol) (tbl :: TableKind) (x :: Type -> Type) (k :: Type -> Type) where
  gTableLookupTables :: Proxy sel -> Proxy tbl -> x p -> k p -> (TableName, [ColumnName])

-- | We use this function to continue searching once we've already found
-- a match, and to abort if we find a second match.
--
class GTableLookupTablesExpectFail (sel :: Maybe Symbol) (tbl :: TableKind) (x :: Type -> Type) (k :: Type -> Type) where
  gTableLookupTablesExpectFail :: Proxy sel -> Proxy tbl -> (TableName, [ColumnName]) -> x p -> k p -> (TableName, [ColumnName])

instance
  (GTableLookupSettings sel tbl x)
  => GTableLookupSettings sel tbl (D1 f x) where
  gTableLookupSettings sel tbl (M1 x) = gTableLookupSettings sel tbl x

instance
  (GTableLookupTables sel tbl x U1)
  => GTableLookupSettings sel tbl (C1 f x) where
  gTableLookupSettings sel tbl (M1 x) = gTableLookupTables sel tbl x U1

instance
  (GTableLookupTables sel tbl x k)
  => GTableLookupTables sel tbl (S1 f x) k where
  gTableLookupTables sel tbl (M1 x) k = gTableLookupTables sel tbl x k

instance
  ( GTableLookupTables sel tbl a (b :*: k)
  ) => GTableLookupTables sel tbl (a :*: b) k where
  gTableLookupTables sel tbl (a :*: b) k = gTableLookupTables sel tbl a (b :*: k)

instance
  (GTableLookupTablesExpectFail sel tbl x k)
  => GTableLookupTablesExpectFail sel tbl (S1 f x) k where
  gTableLookupTablesExpectFail sel tbl r (M1 x) k = gTableLookupTablesExpectFail sel tbl r x k

instance
  ( GTableLookupTablesExpectFail sel tbl a (b :*: k)
  ) => GTableLookupTablesExpectFail sel tbl (a :*: b) k where
  gTableLookupTablesExpectFail sel tbl r (a :*: b) k = gTableLookupTablesExpectFail sel tbl r a (b :*: k)

instance
  ( GTableLookupTable (TestTableEqual tbl tbl') sel tbl k
  , Beamable tbl'
  , Beam.Table tbl'
  ) =>
  GTableLookupTables sel tbl (K1 R (AnnotatedDatabaseEntity be db (TableEntity tbl'))) k where
  gTableLookupTables sel tbl (K1 annEntity) k =
    let
      entity = annEntity ^. deannotate
      tname  = entity ^. dbEntityDescriptor . dbEntityName
      cnames = pkFieldNames entity
    in
      gTableLookupTable (Proxy @(TestTableEqual tbl tbl')) sel tbl (TableName tname, cnames) k

instance
  ( GTableLookupTableExpectFail (TestTableEqual tbl tbl') sel tbl k
  , Beamable tbl'
  ) =>
  GTableLookupTablesExpectFail sel tbl (K1 R (AnnotatedDatabaseEntity be db (TableEntity tbl'))) k where
  gTableLookupTablesExpectFail sel tbl r (K1 _entity) k =
    gTableLookupTableExpectFail (Proxy @(TestTableEqual tbl tbl')) sel tbl r k

type family TestTableEqual (tbl1 :: TableKind) (tbl2 :: TableKind) :: Bool where
  TestTableEqual tbl tbl = True
  TestTableEqual _   _   = False

class GTableLookupTable (b :: Bool) (sel :: Maybe Symbol) (tbl :: TableKind) (k :: Type -> Type) where
  gTableLookupTable :: Proxy b -> Proxy sel -> Proxy tbl -> (TableName, [ColumnName]) -> k p -> (TableName, [ColumnName])

class GTableLookupTableExpectFail (b :: Bool) (sel :: Maybe Symbol) (tbl :: TableKind) (k :: Type -> Type) where
  gTableLookupTableExpectFail :: Proxy b -> Proxy sel -> Proxy tbl -> (TableName, [ColumnName]) -> k p -> (TableName, [ColumnName])

instance GTableLookupTable True sel tbl U1 where
  gTableLookupTable _ _ _ r _ = r

type LookupAmbiguous (sel :: Maybe Symbol) (tbl :: TableKind) =
  Text "Could not derive foreign key constraint for " :<>: ShowField sel :<>: Text "," :$$:
  Text "because there are several tables of type `" :<>: ShowType tbl :<>: Text "' in the schema."

type LookupFailed (sel :: Maybe Symbol) (tbl :: TableKind) =
  Text "Could not derive foreign key constraint for " :<>: ShowField sel :<>: Text "," :$$:
  Text "because there are no tables of type `" :<>: ShowType tbl :<>: Text "' in the schema."

type family ShowField (sel :: Maybe Symbol) :: ErrorMessage where
  ShowField Nothing    = Text "unnamed field"
  ShowField (Just sel) = Text "field `" :<>: Text sel :<>: Text "'"

instance TypeError (LookupAmbiguous sel tbl) => GTableLookupTableExpectFail True sel tbl k where
  gTableLookupTableExpectFail _ _ _ _ _ = error "impossible"

instance (GTableLookupTablesExpectFail sel tbl k ks) => GTableLookupTable True sel tbl (k :*: ks) where
  gTableLookupTable _ sel tbl r (k :*: ks) = gTableLookupTablesExpectFail sel tbl r k ks

instance TypeError (LookupFailed sel tbl) => GTableLookupTable False sel tbl U1 where
  gTableLookupTable _ _ _ _ = error "impossible"

instance GTableLookupTableExpectFail False sel tbl U1 where
  gTableLookupTableExpectFail _ _ _ r _ = r

instance (GTableLookupTablesExpectFail sel tbl k ks) => GTableLookupTableExpectFail False sel tbl (k :*: ks) where
  gTableLookupTableExpectFail _ sel tbl r (k :*: ks) = gTableLookupTablesExpectFail sel tbl r k ks

instance GTableLookupTables sel tbl k ks => GTableLookupTable False sel tbl (k :*: ks) where
  gTableLookupTable _ sel tbl _ (k :*: ks) =
    gTableLookupTables sel tbl k ks
