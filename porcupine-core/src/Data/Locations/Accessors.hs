{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedLabels           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_GHC "-fno-warn-incomplete-uni-patterns" #-}
{-# OPTIONS_GHC "-fno-warn-missing-signatures" #-}
{-# OPTIONS_GHC "-fno-warn-redundant-constraints" #-}

module Data.Locations.Accessors
  ( module Control.Monad.ReaderSoup.Resource
  , FromJSON(..), ToJSON(..)
  , LocationAccessor(..)
  , LocOf, LocWithVarsOf
  , SomeGLoc(..), SomeLoc, SomeLocWithVars
  , SomeHashableLocs
  , toHashableLocs
  , FieldWithAccessors
  , Rec(..), ElField(..)
  , MayProvideLocationAccessors(..)
  , SomeLocationAccessor(..)
  , AvailableAccessors
  , LocResolutionM
  , BasePorcupineContexts
  , (<--)
  , baseContexts, baseContextsWithScribeParams
  , pattern L
  , splitAccessorsFromArgRec
  , withParsedLocs, withParsedLocsWithVars, resolvePathToSomeLoc, resolveYamlDocToSomeLoc
  , writeLazyByte, readLazyByte, readText, writeText
  ) where

import           Control.Funflow.ContentHashable
import           Control.Lens                      (over, (^.), _1)
import           Control.Monad.IO.Unlift
import           Control.Monad.ReaderSoup
import           Control.Monad.ReaderSoup.Resource
import           Control.Monad.Trans.Resource
import           Data.Aeson
import qualified Data.ByteString.Lazy              as LBS
import qualified Data.ByteString.Streaming         as BSS
import qualified Data.HashMap.Strict               as HM
import           Data.Locations.Loc
import           Data.Locations.LogAndErrors
import qualified Data.Text                         as T
import qualified Data.Text.Encoding                as TE
import qualified Data.Text.Lazy                    as LT
import qualified Data.Text.Lazy.Encoding           as LTE
import           Data.Vinyl
import           Data.Vinyl.Functor
import qualified Data.Yaml                         as Y
import           GHC.TypeLits
import           Katip
import           System.Directory                  (createDirectoryIfMissing,
                                                    createFileLink,
                                                    doesPathExist)
import qualified System.FilePath                   as Path
import qualified System.IO.Temp                    as Tmp
import           System.TaskPipeline.Logger


-- | A location where no variables left to be instanciated.
type LocOf l = GLocOf l String

-- | A location that contains variables needing to be instanciated.
type LocWithVarsOf l = GLocOf l StringWithVars

-- | Creates some Loc type, indexed over a symbol (see ReaderSoup for how that
-- symbol should be used), and equipped with functions to access it in some
-- Monad
class ( MonadMask m, MonadIO m
      , TypedLocation (GLocOf l) )
   => LocationAccessor m (l::Symbol) where

  -- | Generalized location. The implementation is completely to the discretion
  -- of the LocationAccessor, but it must be serializable in json, and it must
  -- be able to contain "variable bits" (that will correspond for instance to
  -- indices). These "variable bits" must be exposed through the parameter @a@
  -- in @GLocOf l a@, and @GLocOf l@ must be a Traversable. @a@ will always be
  -- an instance of 'IsLocString'. The rest of the implementation of
  -- 'LocationAccessor' doesn't have to work in the most general case @GLocOf l
  -- a@, as when all variables have been replaced by their final values, @a@ is
  -- just @String@.
  data GLocOf l :: * -> *

  locExists :: LocOf l -> m Bool

  writeBSS :: LocOf l -> BSS.ByteString m r -> m r

  readBSS :: LocOf l -> BSS.ByteString m ()

  copy :: LocOf l -> LocOf l -> m ()
  copy locFrom locTo = writeBSS locTo (readBSS locFrom)

  withLocalBuffer :: (FilePath -> m a) -> LocOf l -> m a
  -- If we have a local resource accessor, we use it:
  default withLocalBuffer :: (MonadResource m)
                          => (FilePath -> m a) -> LocOf l -> m a
  withLocalBuffer f loc =
    Tmp.withSystemTempDirectory "pipeline-tools-tmp" writeAndUpload
    where
      writeAndUpload tmpDir = do
        let tmpFile = tmpDir Path.</> "out"
        res <- f tmpFile
        writeBSS loc $ readBSS (L (localFile tmpFile))
        return res

-- | Reifies an instance of LocationAccessor
data SomeLocationAccessor m where
  SomeLocationAccessor :: (KnownSymbol l, LocationAccessor m l)
                       => Label l -> SomeLocationAccessor m

-- | This class is meant to be implemented by every label used in the reader
-- soup. It tells whether this label provides LocationAccessors (usually zero or
-- 1).
class MayProvideLocationAccessors m l where
  getLocationAccessors :: Label l -> [SomeLocationAccessor m]
  default getLocationAccessors :: (KnownSymbol l, LocationAccessor m l)
                               => Label l -> [SomeLocationAccessor m]
  getLocationAccessors x = [SomeLocationAccessor x]

-- | By default, no accessor is provided
instance {-# OVERLAPPABLE #-} MayProvideLocationAccessors m l where
  getLocationAccessors _ = []

-- | Packs together the args to run a context of the ReaderSoup, and if
-- available, an instance of LocationAccessor
type FieldWithAccessors m =
  Compose ((,) [SomeLocationAccessor m]) ElField

-- | Much like (=:) builds an ElField, (<--) builds a Field composed with
-- LocationAccessors (if available)
(<--) :: (KnownSymbol l, MayProvideLocationAccessors m l)
      => Label l -> args -> FieldWithAccessors m (l:::args)
lbl <-- args = Compose (getLocationAccessors lbl, lbl =: args)

-- | All the LocationAccessors available to the system during a run, so that
-- when we encounter an Aeson Value corresponding to some LocOf, we may try them
-- all and use the first one that matches.
newtype AvailableAccessors m = AvailableAccessors [SomeLocationAccessor m]

-- | Retrieves the list of all available LocationAccessors
--
-- The ArgsForSoupConsumption constraint is redundant, but it is placed here to
-- help type inference when using this function.
splitAccessorsFromArgRec
  :: (ArgsForSoupConsumption args)
  => Rec (FieldWithAccessors (ReaderSoup (ContextsFromArgs args))) args
  -> ( AvailableAccessors (ReaderSoup (ContextsFromArgs args))
     , Rec ElField args )
splitAccessorsFromArgRec = over _1 AvailableAccessors . rtraverse getCompose
  -- `(,) a` is an Applicative if a is a Monoid, so this will merge all the lists
  -- of SomeLocationAccessors

-- * Making "resource" a LocationAccessor

checkLocal :: String -> Loc -> (LocalFilePath -> p) -> p
checkLocal _ (LocalFile fname) f = f fname
checkLocal funcName loc _ = error $ funcName ++ ": location " ++ show loc ++ " isn't a LocalFile"

-- | Accessing local resources
instance (MonadResource m, MonadMask m) => LocationAccessor m "resource" where
  newtype GLocOf "resource" a = L (URL a)
    deriving (Functor, Foldable, Traversable, ToJSON, TypedLocation)
  locExists (L l) = checkLocal "locExists" l $
    liftIO . doesPathExist . (^. pathWithExtensionAsRawFilePath)
  writeBSS (L l) body = checkLocal "writeBSS" l $ \path -> do
    let raw = path ^. pathWithExtensionAsRawFilePath
    liftIO $ createDirectoryIfMissing True (Path.takeDirectory raw)
    BSS.writeFile raw body
  readBSS (L l) = checkLocal "readBSS" l $ \path ->
    BSS.readFile $ path ^. pathWithExtensionAsRawFilePath
  withLocalBuffer f (L l) = checkLocal "withLocalBuffer" l $ \path ->
    f $ path ^. pathWithExtensionAsRawFilePath
  copy (L l1) (L l2) =
    checkLocal "copy" l1 $ \path1 ->
    checkLocal "copy (2nd argument)" l2 $ \path2 ->
      liftIO $ createFileLink
        (path1 ^. pathWithExtensionAsRawFilePath)
        (path2 ^. pathWithExtensionAsRawFilePath)

instance (MonadResource m, MonadMask m) => MayProvideLocationAccessors m "resource"

instance (IsLocString a) => Show (GLocOf "resource" a) where
  show (L l) = show l  -- Not automatically derived to avoid the 'L' constructor
                       -- being added

instance (IsLocString a) => FromJSON (GLocOf "resource" a) where
  parseJSON v = do
    loc <- parseJSON v
    case loc of
      LocalFile{} -> return $ L loc
      _           -> fail "Isn't a local file"


-- * Treating locations in a general manner

-- | Some generalized location. Wraps a @GLocOf l a@ where @l@ is a
-- 'LocationAccessor' in monad @m@.
data SomeGLoc m a = forall l. (LocationAccessor m l) => SomeGLoc (GLocOf l a)

instance Functor (SomeGLoc m) where
  fmap f (SomeGLoc l) = SomeGLoc $ fmap f l
instance Foldable (SomeGLoc m) where
  foldMap f (SomeGLoc l) = foldMap f l
instance Traversable (SomeGLoc m) where
  traverse f (SomeGLoc l) = SomeGLoc <$> traverse f l

type SomeLoc m = SomeGLoc m String
type SomeLocWithVars m = SomeGLoc m StringWithVars

instance Show (SomeLoc m) where
  show (SomeGLoc l) = show l
instance Show (SomeLocWithVars m) where
  show (SomeGLoc l) = show l

instance ToJSON (SomeLoc m) where
  toJSON (SomeGLoc l) = toJSON l
instance ToJSON (SomeLocWithVars m) where
  toJSON (SomeGLoc l) = toJSON l

-- | 'SomeLoc' turned into something that can be hashed
newtype SomeHashableLocs = SomeHashableLocs [Value]
  -- TODO: We go through Aeson.Value representation of the locations to update
  -- the hash. That's not terribly efficient, we should measure if that's a
  -- problem.

instance (Monad m) => ContentHashable m SomeHashableLocs where
  contentHashUpdate ctx (SomeHashableLocs vals) = contentHashUpdate ctx vals

toHashableLocs :: [SomeLoc m] -> SomeHashableLocs
toHashableLocs = SomeHashableLocs . map toJSON

-- * Some helper functions to directly read write/read bytestring into/from
-- locations

writeLazyByte
  :: (LocationAccessor m l)
  => LocOf l
  -> LBS.ByteString
  -> m ()
writeLazyByte loc = writeBSS loc . BSS.fromLazy

-- The following functions are DEPRECATED, because converting to a lazy
-- ByteString with BSS.toLazy_ isn't actually lazy

readLazyByte
  :: (LocationAccessor m l)
  => LocOf l
  -> m LBS.ByteString
readLazyByte loc = BSS.toLazy_ $ readBSS loc

readText
  :: (LocationAccessor m l)
  => LocOf l
  -> m T.Text
readText loc =
  LT.toStrict . LTE.decodeUtf8 <$> readLazyByte loc

writeText
  :: (LocationAccessor m l)
  => LocOf l
  -> T.Text
  -> m ()
writeText loc = writeBSS loc . BSS.fromStrict . TE.encodeUtf8


-- * Base contexts, providing LocationAccessor to local filesystem resources

type BasePorcupineContexts =
  '[ "katip" ::: ContextFromName "katip"
   , "resource" ::: ContextFromName "resource" ]

-- | Use it as the base of the record you give to 'runPipelineTask'. Use '(:&)'
-- to stack other contexts and LocationAccessors on top of it
baseContexts topNamespace =
     #katip    <-- ContextRunner (runLogger topNamespace maxVerbosityLoggerScribeParams)
  :& #resource <-- useResource
  :& RNil

-- | Like 'baseContext' but allows you to set the 'LoggerScribeParams'. Useful
-- when no CLI is used (see 'NoConfig' and 'ConfigFileOnly')
baseContextsWithScribeParams topNamespace scribeParams =
     #katip    <-- ContextRunner (runLogger topNamespace scribeParams)
  :& #resource <-- useResource
  :& RNil

-- * Parsing and resolving locations, tying them to one LocationAccessor

-- | The context in which aeson Values can be resolved to actual Locations
type LocResolutionM m = ReaderT (AvailableAccessors m) m

newtype ErrorsFromAccessors = ErrorsFromAccessors Object
  deriving (ToObject, ToJSON)
instance LogItem ErrorsFromAccessors where
  payloadKeys _ _ = AllKeys

errsFromAccs :: Object -> ErrorsFromAccessors
errsFromAccs = ErrorsFromAccessors . HM.singleton "errorsFromAccessors" . Object

-- | Finds in the accessors list a way to parse a list of JSON values that
-- should correspond to some `LocOf l` type
withParsedLocsWithVars
  :: (LogThrow m)
  => [Value]
  -> (forall l. (LocationAccessor m l)
      => [LocWithVarsOf l] -> LocResolutionM m r)
  -> LocResolutionM m r
withParsedLocsWithVars aesonVals f = do
  AvailableAccessors allAccessors <- ask
  case allAccessors of
    [] -> throwWithPrefix $ "List of accessors is empty"
    _  -> return ()
  loop allAccessors mempty
  where
    showJ = LT.unpack . LT.intercalate ", " . map (LTE.decodeUtf8 . encode)
    loop [] errCtxs =
      katipAddContext (errsFromAccs errCtxs) $
      throwWithPrefix $ "Location(s) " ++ showJ aesonVals
      ++ " cannot be used by the location accessors in place."
    loop (SomeLocationAccessor (lbl :: Label l) : accs) errCtxs =
      case mapM fromJSON aesonVals of
        Success a -> f (a :: [LocWithVarsOf l])
        Error e   -> loop accs (errCtxs <>
                                HM.singleton (T.pack $ symbolVal lbl) (String $ T.pack e))

-- | Finds in the accessors list a way to parse a list of JSON values that
-- should correspond to some `LocOf l` type
withParsedLocs
  :: (LogThrow m)
  => [Value]
  -> (forall l. (LocationAccessor m l)
      => [LocOf l] -> LocResolutionM m r)
  -> LocResolutionM m r
withParsedLocs aesonVals f = do
  AvailableAccessors allAccessors <- ask
  case allAccessors of
    [] -> throwWithPrefix $ "List of accessors is empty"
    _  -> return ()
  loop allAccessors mempty
  where
    showJ = LT.unpack . LT.intercalate ", " . map (LTE.decodeUtf8 . encode)
    loop [] errCtxs =
      katipAddContext (errsFromAccs errCtxs) $
      throwWithPrefix $ "Location(s) " ++ showJ aesonVals
      ++ " cannot be used by the location accessors in place."
    loop (SomeLocationAccessor (lbl :: Label l) : accs) errCtxs =
      case mapM fromJSON aesonVals of
        Success a -> f (a :: [LocOf l])
        Error e   -> loop accs (errCtxs <>
                                HM.singleton (T.pack $ symbolVal lbl) (String $ T.pack e))

-- | The string will be parsed as a YAML value. It can be a simple string or the
-- representation used by some location acccessor. Every accessor will be
-- tried. Will fail if no accessor can handle the YAML value.
resolveYamlDocToSomeLoc
  :: (LogThrow m)
  => String
  -> LocResolutionM m (SomeLoc m)
resolveYamlDocToSomeLoc doc = do
  val <- Y.decodeThrow $ TE.encodeUtf8 $ T.pack doc
  withParsedLocs [val] $ \[l] -> return $ SomeGLoc l

-- | For locations which can be expressed as a simple String. The path will be
-- used as a JSON string. Will fail if no accessor can handle the path.
resolvePathToSomeLoc
  :: (LogThrow m)
  => FilePath
  -> LocResolutionM m (SomeLoc m)
resolvePathToSomeLoc p =
  withParsedLocs [String $ T.pack p] $ \[l] -> return $ SomeGLoc l
