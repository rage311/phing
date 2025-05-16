{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent
import Control.Monad
import Data.Binary
import Data.Bits
import Data.IORef
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List
import Data.Maybe
import Data.Time
import Network.Socket
import Network.Socket.ByteString (recvFrom, sendAll)
import Text.Printf

import ICMP

pingListen :: Socket -> Chan Message -> IO ()
pingListen sock chan = forever $ do
  (recvData, sockAddr) <- recvFrom sock 1024
  --print recvData
  recvTime <- getCurrentTime

  -- skip IP header
  let icmp = drop 20 $ BS.unpack recvData
  let ping = decode (BSL.pack icmp) :: PingPacket
  --print $ "received ping: " <> show ping
  let refId' = mkRefId (ident ping) (seqNum ping)
  putStrLn $
    "Received reply for refId " <> show refId'
    <> " from: " <> show sockAddr
  -- mapM_ (printf "%02x ") $ BS.unpack recvData
  writeChan chan $ PingReceived (refId', recvTime)
  putStrLn ""

data Message
  = PingSent (Word32, UTCTime)
  | PingReceived (Word32, UTCTime)

pingResult :: IO ()
pingResult = return ()

mkIdent :: Word16
mkIdent = 0

mkRefId :: Word16 -> Word16 -> Word32
mkRefId ident seqNum = fromIntegral ident .<<. 16 .|. fromIntegral seqNum

sendPing :: Socket -> Chan Message -> Word16 -> Word16 -> BS.ByteString -> IO ()
sendPing sock chan ident seqNum payload = do
  let ping = mkChecksum $
        defaultPingRequest
          { ident
          , seqNum
          , payload
          }

  sendAll sock $ BS.toStrict $ encode ping
  getCurrentTime >>= \now ->
    writeChan chan $ PingSent (mkRefId ident seqNum, now)

removeRef :: Word32 -> IORef [(Word32, UTCTime)] -> Bool -> IO ()
removeRef refId refs timedOut = do
  rs <- readIORef refs
  let idx = findIndex (\(refId', _) -> refId' == refId) rs

  when (isJust idx) $ do
    if timedOut then
      putStrLn $ "Timed out: " <> show refId
    else
      putStrLn $ "DEBUG: Removing ref (not a timeout) " <> show refId
    modifyIORef' refs $ filter (\(refId', _) -> refId' /= refId)

data PingStatus
  = Sent
  -- round trip time
  | Received Double
  -- timeout time -- duration or UTCTime for this?
  | TimedOut Double
  deriving (Eq, Show)

-- data PingResult
--   = PingReply
--   | Timeout

data PingRef = PingRef
  { refId    :: Word32 -- ident << 16 | seqNum
  -- , packet    :: PingPacket
  , sentTime :: UTCTime
  , recvTime :: Maybe UTCTime
  , status   :: PingStatus
  }
  deriving (Eq, Show)

mkPingRef :: Word32 -> UTCTime -> PingRef
mkPingRef refId sentTime = PingRef
  { refId
  , sentTime
  , recvTime = Nothing
  , status   = Sent
  }

pingMaster :: Chan Message -> IO ()
pingMaster chan = do
  refs    <- newIORef []
  forever $ do
    readChan chan >>= \case
      (PingSent (refId', atTime)) -> do
        putStrLn $ "Sent: " <> show refId' <> " @ " <> show atTime
        modifyIORef refs $ \rs -> (refId', atTime) : rs
        -- start timeout timer
        _ <- forkIO $ do
          threadDelay $ 4000 * 1000
          removeRef refId' refs True
        return ()
      (PingReceived (refId', atTime)) -> do
        putStrLn $ "Recv: refId " <> show refId' <> " @ " <> show atTime
        readIORef refs >>= \rs ->
          case lookup refId' rs of
            (Just sentAtTime) -> do
              removeRef refId' refs False
              putStrLn $ printf "%.1f ms\n"
                ((realToFrac $
                    nominalDiffTimeToSeconds (diffUTCTime atTime sentAtTime) :: Double
                 ) * 1000.0)
            Nothing -> putStrLn $ "No match for seqNum: " <> show refId'

main :: IO ()
main = do
  let intervalSec = 1000 * 5000
  let ident       = 666
  addr <-
    head <$> getAddrInfo
      (Just defaultHints
          { addrFlags      = [AI_ADDRCONFIG]
          , addrSocketType = Raw
          , addrProtocol   = 1
      })
      (Just "8.8.8.8")
      Nothing
  print addr

  chan <- newChan :: IO (Chan Message)

  sock <- openSocket addr
  print sock
  print $ addrAddress addr
  connect sock (addrAddress addr)

  let pings =
        map (\seqNum -> do
          sendPing sock chan ident seqNum "your mom goes to college"
          threadDelay intervalSec
        ) [0..]

  _listenThreadId <- forkIO $ pingListen sock chan
  _masterThreadId <- forkIO $ pingMaster chan

  forever $ sequence_ pings

  -- return ()
