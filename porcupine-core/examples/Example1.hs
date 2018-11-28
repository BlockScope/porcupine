{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

import           Data.Aeson
import           Data.DocRecord
import qualified Data.HashMap.Strict as HM
import qualified Data.Text           as T
import           GHC.Generics
import           Porcupine.Run
import           Porcupine.Serials
import           Porcupine.Tasks


data User = User { userName    :: T.Text
                 , userSurname :: T.Text
                 , userAge     :: Int }
  deriving (Generic)
instance FromJSON User

newtype Analysis = Analysis { numLetters :: HM.HashMap Char Int }
  deriving (Generic)
instance ToJSON Analysis

-- | How to load users
userFile :: DataSource User
userFile = dataSource ["Inputs", "User"]
                      (somePureDeserial JSONSerial)

-- | How to write analysis
analysisFile :: DataSink Analysis
analysisFile = dataSink ["Outputs", "Analysis"]
                        (somePureSerial JSONSerial)

-- | The simple computation we want to perform
computeAnalysis :: User -> Analysis
computeAnalysis (User name surname _) = Analysis $
  HM.fromListWith (+) $ [(c,1) | c <- T.unpack name]
                     ++ [(c,1) | c <- T.unpack surname]

-- | The task combining the three previous operations.
--
-- This task may look very opaque from the outside, having no parameters and no
-- return value. But we will be able to reuse it over different users without
-- having to change it at all.
analyseOneUser :: (LocationMonad m, KatipContext m) => PTask m () ()
analyseOneUser =
  loadData userFile >>> arr computeAnalysis >>> writeData analysisFile

mainTask :: (LocationMonad m, KatipContext m) => PTask m () ()
mainTask =
  -- First we get the ids of the users that we want to analyse. We need only one
  -- field that will contain a range of values, see IndexRange. By default, this
  -- range contains just one value, zero.
  getOption ["Settings"] (docField @"users" (oneIndex (0::Int)) "The user ids to load")
  -- We turn the range we read into a full lazy list:
  >>> arr enumIndices
  -- Then we just map over these ids and call analyseOneUser each time:
  >>> parMapTask_ (repIndex "userId") analyseOneUser

main :: IO ()
main = runPipelineTask_ "example1"
                        (FullConfig "porcupine.yaml" "porcupine-core/examples/data")
                        mainTask
