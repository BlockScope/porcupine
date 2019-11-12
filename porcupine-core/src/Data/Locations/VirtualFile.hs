{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeOperators         #-}

module Data.Locations.VirtualFile
  ( LocationTreePathItem
  , module Data.Locations.SerializationMethod
  , Profunctor(..)
  , VirtualFile(..), LayeredReadScheme(..)
  , BidirVirtualFile, DataSource, DataSink
  , VFileIntent(..), VFileDescription(..)
  , RecOfOptions(..)
  , VFileImportance(..)
  , Cacher(..)
  , vfileSerials
  , vfileAsBidir, vfileImportance
  , vfileEmbeddedValue
  , getConvertedEmbeddedValue, setConvertedEmbeddedValue
  , tryMergeLayersForVFile
  , vfileOriginalPath, showVFileOriginalPath
  , vfileLayeredReadScheme
  , vfileVoided
  , vfiReadSuccess, vfiWriteSuccess, vfiError
  , dataSource, dataSink, bidirVirtualFile
  , makeSink, makeSource
  , documentedFile
  , withEmbeddedValue
  , usesLayeredMapping, canBeUnmapped, unmappedByDefault
  , usesCacherWithIdent
  , getVFileDescription
  , describeVFileAsSourceSink, describeVFileExtensions, describeVFileTypes
  , describeVFileAsRecOfOptions
  , clockVFileAccesses
  , defaultCacherWithIdent
  ) where

import           Control.Funflow
import           Control.Funflow.ContentHashable
import           Control.Lens
import           Data.Aeson                         (Value)
import           Data.Default
import           Data.DocRecord
import qualified Data.HashMap.Strict                as HM
import qualified Data.HashSet                       as HS
import           Data.List                          (intersperse)
import           Data.List.NonEmpty                 (NonEmpty (..))
import           Data.Locations.Accessors
import           Data.Locations.Loc
import           Data.Locations.LocationTree
import           Data.Locations.LocVariable
import           Data.Locations.Mappings            (HasDefaultMappingRule (..),
                                                     LocShortcut (..))
import           Data.Locations.SerializationMethod
import           Data.Maybe
import           Data.Monoid                        (First (..))
import           Data.Profunctor                    (Profunctor (..))
import           Data.Representable
import           Data.Semigroup                     (sconcat)
import           Data.Store                         (Store)
import qualified Data.Text                          as T
import           Data.Type.Equality
import           Data.Typeable
import           Katip


-- * The general 'VirtualFile' type

-- | Tells how the file is meant to be read
data LayeredReadScheme b where
  SingleLayerRead     :: LayeredReadScheme b
    -- No layered reading accepted
  LayeredRead         :: Semigroup b => LayeredReadScheme b
    -- A layered reading combining all the layers with (<>)
  LayeredReadWithNull :: Monoid b => LayeredReadScheme b
    -- Like 'LayeredRead', and handles mapping to no layer (mempty)

-- | Tells how the accesses to this 'VirtualFile' should be logged
data VFileImportance = VFileImportance
  { _vfiReadSuccess  :: Severity
  , _vfiWriteSuccess :: Severity
  , _vfiError        :: Severity
  , _vfiClockAccess  :: Bool }
  deriving (Show)

makeLenses ''VFileImportance

instance Default VFileImportance where
  def = VFileImportance InfoS NoticeS ErrorS False

-- | A virtual file in the location tree to which we can write @a@ and from
-- which we can read @b@.
data VirtualFile a b = VirtualFile
  { _vfileOriginalPath      :: [LocationTreePathItem]
  , _vfileLayeredReadScheme :: LayeredReadScheme b
  , _vfileEmbeddedValue     :: Maybe b
  , _vfileMappedByDefault   :: Bool
  , _vfileImportance        :: VFileImportance
  , _vfileDocumentation     :: Maybe T.Text
  , _vfileWriteCacher       :: Cacher (a, Either String SomeHashableLocs) ()
  , _vfileReadCacher        :: Cacher (Either String SomeHashableLocs) b
  , _vfileSerials           :: SerialsFor a b }

makeLenses ''VirtualFile

-- How we derive the default configuration for mapping some VirtualFile
instance HasDefaultMappingRule (VirtualFile a b) where
  getDefaultLocShortcut vf = if vf ^. vfileMappedByDefault
    then Just $
      case vf ^? vfileSerials . serialRepetitionKeys . filtered (not . null) of
        Nothing -> DeriveWholeLocFromTree defExt
        -- LIMITATION: For now we suppose that every reading/writing function in
        -- the serials has the same repetition keys
        Just rkeys -> DeriveLocPrefixFromTree $
          let toVar rkey = SoV_Variable rkey
              locStr = StringWithVars $ (SoV_String "-")
                       : intersperse (SoV_String "-") (map toVar rkeys)
          in PathWithExtension locStr $ T.unpack defExt
    else Nothing
    where
      defExt =
        case vf ^. vfileSerials . serialDefaultExt of
          First (Just ext) -> ext
          _                -> T.pack ""

-- For now, given the requirement of PTask, VirtualFile has to be a Monoid
-- because a VirtualTree also has to.
instance Semigroup (VirtualFile a b) where
  VirtualFile p l v m i d wc rc s <> VirtualFile _ _ _ _ _ _ _ _ s' =
    VirtualFile p l v m i d wc rc (s<>s')
instance Monoid (VirtualFile a b) where
  mempty = VirtualFile [] SingleLayerRead Nothing True def Nothing NoCache NoCache mempty

-- | The Profunctor instance is forgetful, it forgets about the mapping scheme
-- and the caching properties.
instance Profunctor VirtualFile where
  dimap f g (VirtualFile p _ v m i d _ _ s) =
    VirtualFile p SingleLayerRead (g <$> v) m i d NoCache NoCache $ dimap f g s


-- * Obtaining a description of how the 'VirtualFile' should be used

-- | Describes how a virtual file is meant to be used
data VFileIntent =
  VFForWriting | VFForReading | VFForRW | VFForCLIOptions
  deriving (Show, Eq)

-- | Gives the purpose of the 'VirtualFile'. Used to document the pipeline and check
-- mappings to physical files.
data VFileDescription = VFileDescription
  { vfileDescIntent             :: Maybe VFileIntent
                        -- ^ How is the 'VirtualFile' meant to be used
  , vfileDescEmbeddableInConfig :: Bool
                        -- ^ True if the data can be read directly from the
                        -- pipeline's config file
  , vfileDescEmbeddableInOutput :: Bool
                        -- ^ True if the data can be written directly in the
                        -- pipeline's output location tree
  , vfileDescPossibleExtensions :: [FileExt]
                        -- ^ Possible extensions for the files this virtual file
                        -- can be mapped to (prefered extension is the first)
  } deriving (Show)

-- | Gives a 'VirtualFileDescription'. To be used on files stored in the
-- VirtualTree.
getVFileDescription :: VirtualFile a b -> VFileDescription
getVFileDescription vf =
  VFileDescription intent readableFromConfig writableInOutput exts
  where
    (SerialsFor
      (SerialWriters toA)
      (SerialReaders fromA fromS)
      prefExt
      _) = _vfileSerials vf
    intent
      | HM.null fromA && HM.null fromS && HM.null toA = Nothing
      | HM.null fromA && HM.null fromS = Just VFForWriting
      | HM.null toA = Just VFForReading
      | Just _ <- vf ^. vfileEmbeddedValue = Just VFForCLIOptions
      | otherwise = Just VFForRW
    extSet = HS.fromList . mapMaybe snd . HM.keys
    otherExts = extSet toA <> extSet fromA <> extSet fromS
    exts = case prefExt of
             First (Just e) -> e:(HS.toList $ HS.delete e otherExts)
             _              -> HS.toList otherExts
    typeOfAesonVal = typeOf (undefined :: Value)
    readableFromConfig = (typeOfAesonVal,Nothing) `HM.member` fromA
    writableInOutput = (typeOfAesonVal,Nothing) `HM.member` toA

describeVFileAsSourceSink :: VirtualFile a b -> String
describeVFileAsSourceSink vf =
  sourceSink
  ++ (if vfileDescEmbeddableInConfig vfd then " (embeddable)" else "")
  ++ (case vf ^. vfileSerials.serialRepetitionKeys of
        [] -> ""
        lvs -> " repeated over " ++ concat
          (intersperse ", " (map (("\""++) . (++"\"") . unLocVariable) lvs)))
  where
    sourceSink = case vfileDescIntent vfd of
      Nothing -> ""
      Just i -> case i of
        VFForWriting    -> "DATA SINK"
        VFForReading    -> "DATA SOURCE"
        VFForRW         -> "BIDIR VFILE"
        VFForCLIOptions -> "OPTION SOURCE"
    vfd = getVFileDescription vf

describeVFileAsRecOfOptions :: (Typeable a, Typeable b) => VirtualFile a b -> Int -> String
describeVFileAsRecOfOptions vf charLimit =
  case (vf ^? vfileAsBidir) >>= getConvertedEmbeddedValue of
    Just (RecOfOptions record :: DocRecOfOptions) ->
      "\n--- Fields ---\n" ++ T.unpack (showDocumentation charLimit record)
    _ -> ""

describeVFileExtensions :: VirtualFile a b -> String
describeVFileExtensions vf =
  "Accepts " ++ T.unpack (T.intercalate (T.pack ", ") (vfileDescPossibleExtensions vfd))
  where vfd = getVFileDescription vf

describeVFileTypes :: forall a b. (Typeable a, Typeable b) => VirtualFile a b -> Int -> String
describeVFileTypes _ charLimit
  | a == b = "Receives & emits: " ++ cap (show a)
  | b == typeOf (undefined :: NoRead) = "Receives " ++ cap (show a)
  | a == typeOf (undefined :: NoWrite) = "Emits " ++ cap (show b)
  | otherwise = "Receives " ++ cap (show a) ++ " & emits " ++ cap (show b)
  where
    cap x | length x >= charLimit = take charLimit x ++ "..."
          | otherwise = x
    a = typeOf (undefined :: a)
    b = typeOf (undefined :: b)

-- | Just for logs and error messages
showVFileOriginalPath :: VirtualFile a b -> String
showVFileOriginalPath = T.unpack . toTextRepr .  LTP . _vfileOriginalPath

-- | Embeds a value inside the 'VirtualFile'. This value will be considered the
-- base layer if we read extra @b@'s from external physical files.
withEmbeddedValue :: b -> VirtualFile a b -> VirtualFile a b
withEmbeddedValue = set vfileEmbeddedValue . Just

-- | Indicates that the file uses layered mapping
usesLayeredMapping :: (Semigroup b) => VirtualFile a b -> VirtualFile a b
usesLayeredMapping =
  vfileLayeredReadScheme .~ LayeredRead

-- | Indicates that the file uses layered mapping, and additionally can be left
-- unmapped (ie. mapped to null)
canBeUnmapped :: (Monoid b) => VirtualFile a b -> VirtualFile a b
canBeUnmapped =
  vfileLayeredReadScheme .~ LayeredReadWithNull

-- | Indicates that the file should be mapped to null by default
unmappedByDefault :: (Monoid b) => VirtualFile a b -> VirtualFile a b
unmappedByDefault =
    (vfileLayeredReadScheme .~ LayeredReadWithNull)
  . (vfileMappedByDefault .~ False)

-- | Gives a documentation to the 'VirtualFile'
documentedFile :: T.Text -> VirtualFile a b -> VirtualFile a b
documentedFile doc = vfileDocumentation .~ Just doc

-- | Sets the file's reads and writes to be cached. Useful if the file is bound
-- to a source/sink that takes time to respond, such as an HTTP endpoint, or
-- that uses an expensive text serialization method (like JSON or XML).
usesCacherWithIdent :: (ContentHashable Identity a, Store b)
                    => Int -> VirtualFile a b -> VirtualFile a b
usesCacherWithIdent ident =
    (vfileWriteCacher .~ defaultCacherWithIdent ident)
  . (vfileReadCacher .~ defaultCacherWithIdent ident)

-- * Creating VirtualFiles and convertings between its different subtypes (bidir
-- files, sources and sinks)

-- | A virtual file which depending on the situation can be written or read
type BidirVirtualFile a = VirtualFile a a

-- | A virtual file that's only readable
type DataSource a = VirtualFile NoWrite a

-- | A virtual file that's only writable
type DataSink a = VirtualFile a NoRead

-- | Creates a virtuel file from its virtual path and ways serialize/deserialize
-- the data. You should prefer 'dataSink' and 'dataSource' for clarity when the
-- file is meant to be readonly or writeonly.
virtualFile :: [LocationTreePathItem] -> SerialsFor a b -> VirtualFile a b
virtualFile path sers = VirtualFile path SingleLayerRead Nothing True def Nothing NoCache NoCache sers

-- | Creates a virtual file from its virtual path and ways to deserialize the
-- data.
dataSource :: [LocationTreePathItem] -> SerialsFor a b -> DataSource b
dataSource path = makeSource . virtualFile path

-- | Creates a virtual file from its virtual path and ways to serialize the
-- data.
dataSink :: [LocationTreePathItem] -> SerialsFor a b -> DataSink a
dataSink path = makeSink . virtualFile path

-- | Like 'virtualFile', but constrained to bidirectional serials, for clarity
bidirVirtualFile :: [LocationTreePathItem] -> BidirSerials a -> BidirVirtualFile a
bidirVirtualFile = virtualFile

-- | Turns the 'VirtualFile' into a pure source
makeSource :: VirtualFile a b -> DataSource b
makeSource vf = vf{_vfileSerials=eraseSerials $ _vfileSerials vf
                  ,_vfileWriteCacher=NoCache}

-- | Turns the 'VirtualFile' into a pure sink
makeSink :: VirtualFile a b -> DataSink a
makeSink vf = vf{_vfileSerials=eraseDeserials $ _vfileSerials vf
                ,_vfileLayeredReadScheme=LayeredReadWithNull
                ,_vfileReadCacher=NoCache
                ,_vfileEmbeddedValue=Nothing}


-- * Traversals to the content of the VirtualFile, when it already embeds some
-- value

-- | If we have the internal proof that a VirtualFile is actually bidirectional,
  -- we convert it.
vfileAsBidir :: forall a b. (Typeable a, Typeable b)
             => Traversal' (VirtualFile a b) (BidirVirtualFile a)
vfileAsBidir f vf = case eqT :: Maybe (a :~: b) of
  Just Refl -> f vf
  Nothing   -> pure vf

-- | Gives access to a version of the VirtualFile without type params. The
-- original path isn't settable.
vfileVoided :: Lens' (VirtualFile a b) (VirtualFile NoWrite NoRead)
vfileVoided f (VirtualFile p l v m i d wc rc s) =
  rebuild <$> f (VirtualFile p SingleLayerRead Nothing m i d NoCache NoCache mempty)
  where
    rebuild (VirtualFile _ _ _ m' i' d' _ _ _) =
      VirtualFile p l v m' i' d' wc rc s

-- | If the 'VirtualFile' has an embedded value convertible to type @i@, we get
-- it.
getConvertedEmbeddedValue
  :: (Typeable i)
  => BidirVirtualFile a
  -> Maybe i
getConvertedEmbeddedValue vf = do
  toA <- getToAtomicFn (vf ^. vfileSerials)
  toA <$> vf ^. vfileEmbeddedValue

-- | If the 'VirtualFile' can hold a embedded value of type @a@ that's
-- convertible from type @i@, we set it. Note that the conversion may fail, we
-- return Left if the VirtualFile couldn't be set.
setConvertedEmbeddedValue
  :: forall a b i. (Typeable i)
  => VirtualFile a b
  -> i
  -> Either String (VirtualFile a b)
setConvertedEmbeddedValue vf i =
  case getFromAtomicFn (vf ^. vfileSerials) of
    Nothing -> Left $ showVFileOriginalPath vf ++
               ": no conversion function is available to transform type " ++ show (typeOf (undefined :: i))
    Just fromA -> do
      i' <- fromA i
      return $ vf & vfileEmbeddedValue .~ Just i'

-- | Tries to convert each @i@ layer to and from type @b@ and find a
-- Monoid/Semigroup instance for @b@ in the vfileLayeredReadScheme, so we can
-- merge these layers. So if we have more that one layer, this will fail if the
-- file doesn't use LayeredRead.
tryMergeLayersForVFile
  :: forall a b i. (Typeable i)
  => VirtualFile a b
  -> [i]
  -> Either String b
tryMergeLayersForVFile vf layers = let ser = vf ^. vfileSerials in
  case getFromAtomicFn ser of
    Nothing -> Left $ showVFileOriginalPath vf ++
               ": no conversion functions are available to transform back and forth type "
               ++ show (typeOf (undefined :: i))
    Just fromA -> do
      case (layers, vf^.vfileLayeredReadScheme) of
        ([], LayeredReadWithNull) -> return mempty
        ([], _) -> Left $ "tryMergeLayersForVFile: " ++ showVFileOriginalPath vf
                   ++ " doesn't support mapping to no layers"
        ([x], _) -> fromA x
        (x:xs, LayeredRead) -> sconcat <$> traverse fromA (x:|xs)
        (xs, LayeredReadWithNull) -> mconcat <$> traverse fromA xs
        (_, _) -> Left $ "tryMergeLayersForVFile: " ++ showVFileOriginalPath vf
                  ++ " cannot use several layers of data"

-- | Sets vfileImportance . vfiClockAccess to True. This way each access to the
-- file will be clocked and logged.
clockVFileAccesses :: VirtualFile a b -> VirtualFile a b
clockVFileAccesses = vfileImportance . vfiClockAccess .~ True
