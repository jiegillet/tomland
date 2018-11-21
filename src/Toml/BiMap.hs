{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE KindSignatures    #-}
{-# LANGUAGE Rank2Types        #-}
{-# LANGUAGE TypeOperators     #-}



{- | Implementation of partial bidirectional mapping as a data type.
-}

module Toml.BiMap  where
       -- ( -- * BiMap idea
       --   BiMap (..)
       -- , invert
       -- , iso
       -- , prism
       --
       --   -- * Helpers for BiMap and AnyValue
       -- , mkAnyValueBiMap
       -- , _TextBy
       -- , _NaturalInteger
       -- , _StringText
       -- , _ReadString
       -- , _BoundedInteger
       -- , _ByteStringText
       -- , _LByteStringText
       --
       --   -- * Some predefined bi mappings
       -- , _Array
       -- , _Bool
       -- , _Double
       -- , _Integer
       -- , _Text
       -- , _ZonedTime
       -- , _LocalTime
       -- , _Day
       -- , _TimeOfDay
       -- , _String
       -- , _Read
       -- , _Natural
       -- , _Word
       -- , _Int
       -- , _Float
       -- , _ByteString
       -- , _LByteString
       -- , _Set
       -- , _IntSet
       -- , _HashSet
       -- , _NonEmpty
       --
       -- , _Left
       -- , _Right
       -- , _Just
       --
       --   -- * Useful utility functions
       -- , toMArray
       -- , GenBiMap(..)
       -- ) where

import Control.Arrow ((>>>))
import Control.Monad ((>=>))

import Data.ByteString (ByteString)
import Data.Hashable (Hashable)
import Data.Text (Text)
import Data.Time (Day, LocalTime, TimeOfDay, ZonedTime)
import Data.Word (Word)
import GHC.Generics
import Numeric.Natural (Natural)
import Text.Read (readMaybe)

import Toml.Type (AnyValue (..), DateTime (..), Value (..), matchArray, matchBool, matchDate,
                  matchDouble, matchInteger, matchText, toMArray)

import qualified Control.Category as Cat
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashSet as HS
import qualified Data.IntSet as IS
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL

----------------------------------------------------------------------------
-- BiMap concepts and ideas
----------------------------------------------------------------------------

{- | Partial bidirectional isomorphism. @BiMap a b@ contains two function:

1. @a -> Maybe b@
2. @b -> Maybe a@
-}
data BiMap a b = BiMap
    { forward  :: a -> Maybe b
    , backward :: b -> Maybe a
    }

instance Cat.Category BiMap where
    id :: BiMap a a
    id = BiMap Just Just

    (.) :: BiMap b c -> BiMap a b -> BiMap a c
    bc . ab = BiMap
        { forward  =  forward ab >=>  forward bc
        , backward = backward bc >=> backward ab
        }

-- | Inverts bidirectional mapping.
invert :: BiMap a b -> BiMap b a
invert (BiMap f g) = BiMap g f

-- | Creates 'BiMap' from isomorphism.
iso :: (a -> b) -> (b -> a) -> BiMap a b
iso f g = BiMap (Just . f) (Just . g)

-- | Creates 'BiMap' from prism-like pair of functions.
prism :: (field -> object) -> (object -> Maybe field) -> BiMap object field
prism review preview = BiMap preview (Just . review)

----------------------------------------------------------------------------
-- General purpose bimaps
----------------------------------------------------------------------------

-- | Bimap for 'Either' and its left type
_Left :: BiMap (Either l r) l
_Left = prism Left (either Just (const Nothing))

-- | Bimap for 'Either' and its right type
_Right :: BiMap (Either l r) r
_Right = prism Right (either (const Nothing) Just)

-- | Bimap for 'Maybe'
_Just :: BiMap (Maybe a) a
_Just = prism Just id

----------------------------------------------------------------------------
--  BiMaps for value
----------------------------------------------------------------------------

-- | Creates prism for 'AnyValue'.
mkAnyValueBiMap :: (forall t . Value t -> Maybe a)
                -> (a -> Value tag)
                -> BiMap a AnyValue
mkAnyValueBiMap matchValue toValue =
    BiMap (Just . AnyValue . toValue) (\(AnyValue value) -> matchValue value)

-- | Creates bimap for 'Text' to 'AnyValue' with custom functions
_TextBy :: (a -> Text) -> (Text -> Maybe a) -> BiMap a AnyValue
_TextBy toText parseText =
  mkAnyValueBiMap (matchText >=> parseText) (Text . toText)

-- | 'Bool' bimap for 'AnyValue'. Usually used with 'bool' combinator.
_Bool :: BiMap Bool AnyValue
_Bool = mkAnyValueBiMap matchBool Bool

-- | 'Integer' bimap for 'AnyValue'. Usually used with 'integer' combinator.
_Integer :: BiMap Integer AnyValue
_Integer = mkAnyValueBiMap matchInteger Integer

-- | 'Double' bimap for 'AnyValue'. Usually used with 'double' combinator.
_Double :: BiMap Double AnyValue
_Double = mkAnyValueBiMap matchDouble Double

-- | 'Text' bimap for 'AnyValue'. Usually used with 'text' combinator.
_Text :: BiMap Text AnyValue
_Text = mkAnyValueBiMap matchText Text

-- | Zoned time bimap for 'AnyValue'. Usually used with 'zonedTime' combinator.
_ZonedTime :: BiMap ZonedTime AnyValue
_ZonedTime = mkAnyValueBiMap (matchDate >=> getTime) (Date . Zoned)
  where
    getTime (Zoned z) = Just z
    getTime _         = Nothing

-- | Local time bimap for 'AnyValue'. Usually used with 'localTime' combinator.
_LocalTime :: BiMap LocalTime AnyValue
_LocalTime = mkAnyValueBiMap (matchDate >=> getTime) (Date . Local)
  where
    getTime (Local l) = Just l
    getTime _         = Nothing

-- | Day bimap for 'AnyValue'. Usually used with 'day' combinator.
_Day :: BiMap Day AnyValue
_Day = mkAnyValueBiMap (matchDate >=> getTime) (Date . Day)
  where
    getTime (Day d) = Just d
    getTime _       = Nothing

-- | Time of day bimap for 'AnyValue'. Usually used with 'timeOfDay' combinator.
_TimeOfDay :: BiMap TimeOfDay AnyValue
_TimeOfDay = mkAnyValueBiMap (matchDate >=> getTime) (Date . Hours)
  where
    getTime (Hours h) = Just h
    getTime _         = Nothing

-- | Helper bimap for 'String' and 'Text'.
_StringText :: BiMap String Text
_StringText = iso T.pack T.unpack

-- | 'String' bimap for 'AnyValue'. Usually used with 'string' combinator.
_String :: BiMap String AnyValue
_String = _StringText >>> _Text

-- | Helper bimap for 'String' and types with 'Read' and 'Show' instances.
_ReadString :: (Show a, Read a) => BiMap a String
_ReadString = BiMap (Just . show) readMaybe

-- | Bimap for 'AnyValue' and values with a `Read` and `Show` instance.
-- Usually used with 'read' combinator.
_Read :: (Show a, Read a) => BiMap a AnyValue
_Read = _ReadString >>> _String

-- | Helper bimap for 'Natural' and 'Integer'.
_NaturalInteger :: BiMap Natural Integer
_NaturalInteger = BiMap (Just . toInteger) maybeInteger
  where
    maybeInteger :: Integer -> Maybe Natural
    maybeInteger n
      | n < 0     = Nothing
      | otherwise = Just (fromIntegral n)

-- | 'Natural' bimap for 'AnyValue'. Usually used with 'natural' combinator.
_Natural :: BiMap Natural AnyValue
_Natural = _NaturalInteger >>> _Integer

-- | Helper bimap for 'Integer' and integral, bounded values.
_BoundedInteger :: (Integral a, Bounded a) => BiMap a Integer
_BoundedInteger = BiMap (Just . toInteger) maybeBounded
  where
    maybeBounded :: forall a. (Integral a, Bounded a) => Integer -> Maybe a
    maybeBounded n
      | n < toInteger (minBound :: a) = Nothing
      | n > toInteger (maxBound :: a) = Nothing
      | otherwise                     = Just (fromIntegral n)

-- | 'Word' bimap for 'AnyValue'. Usually used with 'word' combinator.
_Word :: BiMap Word AnyValue
_Word = _BoundedInteger >>> _Integer

-- | 'Int' bimap for 'AnyValue'. Usually used with 'int' combinator.
_Int :: BiMap Int AnyValue
_Int = _BoundedInteger >>> _Integer

-- | 'Float' bimap for 'AnyValue'. Usually used with 'float' combinator.
_Float :: BiMap Float AnyValue
_Float = iso realToFrac realToFrac >>> _Double

-- | Helper bimap for 'Text' and strict 'ByteString'
_ByteStringText :: BiMap ByteString Text
_ByteStringText = prism T.encodeUtf8 maybeText
  where
    maybeText :: ByteString -> Maybe Text
    maybeText = either (const Nothing) Just . T.decodeUtf8'

-- | 'ByteString' bimap for 'AnyValue'. Usually used with 'byteString' combinator.
_ByteString:: BiMap ByteString AnyValue
_ByteString = _ByteStringText >>> _Text

-- | Helper bimap for 'Text' and lazy 'ByteString'
_LByteStringText :: BiMap BL.ByteString Text
_LByteStringText = prism (TL.encodeUtf8 . TL.fromStrict) maybeText
  where
    maybeText :: BL.ByteString -> Maybe Text
    maybeText = either (const Nothing) (Just . TL.toStrict) . TL.decodeUtf8'

-- | Lazy 'ByteString' bimap for 'AnyValue'. Usually used with 'lazyByteString'
-- combinator.
_LByteString:: BiMap BL.ByteString AnyValue
_LByteString = _LByteStringText >>> _Text

-- | Takes a bimap of a value and returns a bimap of a list of values and 'Anything'
-- as an array. Usually used with 'arrayOf' combinator.
_Array :: BiMap a AnyValue -> BiMap [a] AnyValue
_Array elementBimap = BiMap
    { forward = mapM (forward elementBimap) >=> fmap AnyValue . toMArray
    , backward = \(AnyValue val) -> matchArray (backward elementBimap) val
    }

-- | Takes a bimap of a value and returns a bimap of a non-empty list of values
-- and 'Anything' as an array. Usually used with 'nonEmptyOf' combinator.
_NonEmpty :: BiMap a AnyValue -> BiMap (NE.NonEmpty a) AnyValue
_NonEmpty bimap = BiMap (Just . NE.toList) NE.nonEmpty >>> _Array bimap

-- | Takes a bimap of a value and returns a bimap of a set of values and 'Anything'
-- as an array. Usually used with 'setOf' combinator.
_Set :: (Ord a) => BiMap a AnyValue -> BiMap (S.Set a) AnyValue
_Set bimap = iso S.toList S.fromList >>> _Array bimap

-- | Takes a bimap of a value and returns a bimap of a has set of values and
-- 'Anything' as an array. Usually used with 'hashSetOf' combinator.
_HashSet :: (Eq a, Hashable a) => BiMap a AnyValue -> BiMap (HS.HashSet a) AnyValue
_HashSet bimap = iso HS.toList HS.fromList >>> _Array bimap

-- | Bimap of 'IntSet' and 'Anything' as an array. Usually used with
-- 'intSet' combinator.
_IntSet :: BiMap IS.IntSet AnyValue
_IntSet = iso IS.toList IS.fromList >>> _Array _Int


-- Implementation for Generic data structures

class GenBiMap' f where
  encode' :: f p -> AnyValue
  decode' :: AnyValue -> Maybe (f p)

instance GenBiMap' V1 where
  encode' _ = undefined
  decode' _ = undefined

instance GenBiMap' U1 where
  encode' U1 = AnyValue $ Array []

  decode' (AnyValue (Array [])) = Just U1
  decode' _                     = Nothing

instance (GenBiMap' f, GenBiMap' g) => GenBiMap' (f :+: g) where
  encode' = \case
      (L1 x) -> go False (encode' x)
      (R1 x) -> go True (encode' x)
    where
      go :: Bool -> AnyValue -> AnyValue
      go b (AnyValue v) = AnyValue $ Array [ Array [Bool b], Array [ v ]]

  decode' (AnyValue (Array [ Array [Bool False], Array [ v ]])) =
               L1 <$> decode' (AnyValue v)
  decode' (AnyValue (Array [ Array [Bool True], Array [ v ]])) =
               R1 <$> decode' (AnyValue v)
  decode' _ = Nothing

instance (GenBiMap' f, GenBiMap' g) => GenBiMap' (f :*: g) where
  encode' (x :*: y) = go (encode' x) (encode' y)
    where
      go :: AnyValue -> AnyValue -> AnyValue
      go (AnyValue v) (AnyValue w) = AnyValue $ Array [ Array [ v ], Array [ w ]]

  decode' (AnyValue (Array [ Array [ v ], Array [ w ]])) =
    (:*:) <$> decode' (AnyValue v) <*> decode' (AnyValue w)
  decode' _ = Nothing

instance (GenBiMap c) => GenBiMap' (K1 i c) where
  encode' (K1 x) = encode_ x
  decode' v = K1 <$> decode_ v

instance (GenBiMap' f) => GenBiMap' (M1 i t f) where
  encode' (M1 x) = encode' x
  decode' v = M1 <$> decode' v

class GenBiMap a where
  encode_ :: a -> AnyValue
  default encode_ :: (Generic a, GenBiMap' (Rep a)) => a -> AnyValue
  encode_ x = encode' (from x)
  decode_ :: AnyValue -> Maybe a
  default decode_ :: (Generic a, GenBiMap' (Rep a)) => AnyValue -> Maybe a
  decode_ x = to <$> decode' x

instance GenBiMap AnyValue where
  encode_ = id
  decode_ = Just

instance GenBiMap ()
instance (GenBiMap a, GenBiMap b) => GenBiMap (Either a b)
instance (GenBiMap a, GenBiMap b) => GenBiMap (a, b)
instance (GenBiMap a, GenBiMap b, GenBiMap c) => GenBiMap (a, b, c)
instance (GenBiMap a, GenBiMap b, GenBiMap c, GenBiMap d) => GenBiMap (a, b, c, d)
instance (GenBiMap a) => GenBiMap [a]

newtype AV = AV {unAV :: AnyValue} deriving (Show, Generic)
instance GenBiMap AV

_Generic :: (GenBiMap (f AV), Traversable f) => BiMap a AnyValue -> BiMap (f a) AnyValue
_Generic (BiMap av va) = BiMap (fmap encode_ . sequence . fmap (fmap AV . av) )
                               (decode_ >=> sequence . fmap (va . unAV))

data Tree a = Leaf' a | Node' a (Tree a) (Tree a) deriving (Show, Generic, Functor, Foldable, Traversable)
instance (GenBiMap a) => GenBiMap (Tree a)

_BoolTree :: BiMap (Tree Bool) AnyValue
_BoolTree = _Generic _Bool
