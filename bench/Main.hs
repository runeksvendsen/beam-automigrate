{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Criterion.Main

import           System.Random.SplitMix         ( mkSMGen )
import           Data.ByteString                ( ByteString )
import           Control.Monad.IO.Class         ( liftIO )
import           Control.Exception              ( bracket )
import qualified Data.Map.Strict               as M
import           Control.DeepSeq

import           Test.QuickCheck.Gen
import           Test.QuickCheck.Random

import           Database.Beam.Migrate
import           Database.Beam.Migrate.Schema.Gen
                                                ( genSimilarSchemas )
import           Database.Beam.Migrate.Postgres ( getSchema )

import qualified Database.PostgreSQL.Simple    as Pg
import           Database.Beam.Postgres         ( runBeamPostgres )


newtype SpineStrict = SS { unSS :: Diff }

-- For us is enough to make the list of edits spine-strict.
instance NFData SpineStrict where
    rnf (SS (Left e))      = rnf e
    rnf (SS (Right edits)) = length edits `deepseq` ()

predictableSchemas :: Int -> IO (Schema, Schema)
predictableSchemas tableNum = do
    let g = unGen genSimilarSchemas 
    let r = QCGen (mkSMGen 42)
    return (g r tableNum)

connInfo :: ByteString
connInfo = "host=localhost port=5432 dbname=beam-migrate-prototype-bench"

pgMigrate :: Pg.Connection -> (Schema -> Schema -> Diff) -> Schema -> IO SpineStrict
pgMigrate conn diffFun hsSchema =
  Pg.withTransaction conn $
    runBeamPostgres conn $ do
      dbSchema <- liftIO (getSchema conn)
      pure . SS $ diffFun hsSchema dbSchema

referenceDiff :: Schema -> Schema -> Diff
referenceDiff s1 s2 = diffTablesReferenceImplementation (schemaTables s1) (schemaTables s2)

setupDatabase :: Schema -> IO Pg.Connection
setupDatabase dbSchema = do
  conn <- Pg.connectPostgreSQL connInfo

  Pg.withTransaction conn $
    runBeamPostgres conn $ do
      let mig = createMigration (diff dbSchema noSchema)
      runMigration mig -- At this point the DB contains the full schema.

  pure conn

tearDownDatabase :: Pg.Connection -> IO ()
tearDownDatabase conn = do
   Pg.withTransaction conn $ do
     -- Delete all tables to start from a clean slate
     _ <- Pg.execute_ conn "DROP SCHEMA public CASCADE"
     _ <- Pg.execute_ conn "CREATE SCHEMA public"
     _ <- Pg.execute_ conn "GRANT USAGE ON SCHEMA public TO public"
     _ <- Pg.execute_ conn "GRANT CREATE ON SCHEMA public TO public"
     pure ()
   Pg.close conn

main :: IO ()
main = do
  putStrLn $ "Generating schema with 10_000 tables ..."
  (hsSchema, dbSchema) <- predictableSchemas 10000
  putStrLn $ "Generated schema with " ++  show (M.size . schemaTables $ hsSchema) ++ " tables."
  bracket (setupDatabase dbSchema) tearDownDatabase $ \pgConn ->
    defaultMain [
        bgroup "diff" [ 
            bench "reference/10_000 tables avg. case (similar schema)" $ nf (SS . referenceDiff hsSchema) dbSchema
          , bench "efficient/10_000 tables avg. case (similar schema)" $ nf (SS . diff hsSchema         ) dbSchema
          , bench "reference/10_000 tables worst case (no schema)"     $ nf (SS . referenceDiff hsSchema) noSchema
          , bench "efficient/10_000 tables worst case (no schema)"     $ nf (SS . diff hsSchema         ) noSchema
          ]
      , bgroup "getSchema" [ 
            bench "10_000 tables" $ nfIO (getSchema pgConn)
          ]
      , bgroup "full_migration" [ bench "reference/10_000 tables avg. case (similar schema)"       $ nfIO (pgMigrate pgConn referenceDiff hsSchema)
                                , bench "efficient/10_000 tables avg. case (similar schema)"       $ nfIO (pgMigrate pgConn diff hsSchema)
                                , bench "reference/10_000 tables worst case (no previous schema)"  $ nfIO (pgMigrate pgConn referenceDiff hsSchema)
                                , bench "efficient/10_000 tables worst case (no previous schema)"  $ nfIO (pgMigrate pgConn diff hsSchema)
                                ]
      ]
