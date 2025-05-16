{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module ICMP where

import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits
import Data.ByteString.Builder
import qualified Data.ByteString as BS
import Data.List.Split
import GHC.Generics

data PingPacket = PingPacket
  { msgType  :: Word8
  , code     :: Word8
  , checksum :: Word16
  , ident    :: Word16
  , seqNum   :: Word16
  , payload  :: BS.ByteString
  }
  deriving (Eq, Generic, Show)

instance Binary PingPacket
  where
    get :: Get PingPacket
    get = do
      msgType  <- getWord8
      code     <- getWord8
      checksum <- getWord16be
      ident    <- getWord16be
      seqNum   <- getWord16be
      payload  <- getByteString 0
      return (PingPacket { msgType, code, checksum, ident, seqNum, payload })

    put :: PingPacket -> Put
    put (PingPacket { .. }) = do
      put msgType
      put code
      put checksum
      put ident
      put seqNum
      putByteString payload

defaultPingRequest :: PingPacket
defaultPingRequest = PingPacket
  { msgType  = 8
  , code     = 0
  , checksum = 0
  , ident    = 0
  , seqNum   = 0
  , payload  = ""
  }

-- all the "fromIntegral"s to deal with Word16 overflow
calcChecksum :: Int -> BS.ByteString -> Word16
calcChecksum bits xs = onesComplement magic $
  foldr ((\x acc -> do
      let
          x'    = fromIntegral x + fromIntegral acc
          left  = x' `mod` magic
          carry = x' `div` magic
      fromIntegral left + fromIntegral carry
    ) . makeWord16
  ) 0 (chunksOf 2 (BS.unpack xs))
  where
    magic :: Int
    magic = 2 ^ bits

mkChecksum :: PingPacket -> PingPacket
mkChecksum ping@(PingPacket { msgType, code, ident, seqNum, payload }) =
  ping { checksum }
  where
    words' = map word16BE
      [ makeWord16 [msgType, code]
      , ident
      , seqNum
      ]
    checksumInput = BS.toStrict
      $ toLazyByteString
      $ mconcat words'
      <> byteString payload
    checksum = calcChecksum 16 checksumInput

onesComplement :: Int -> Word16 -> Word16
onesComplement inp = (.^.) $ fromIntegral inp - 1

makeWord16 :: [Word8] -> Word16
makeWord16 (x:y:_) = fromIntegral x .<<. 8 .|. fromIntegral y
makeWord16 (x:_)   = fromIntegral x .<<. 8 .|. 0
makeWord16 []      = 0

