{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- TODO:
--  interrupt handler to print final stats

module Main where

import Control.Concurrent
import Control.Monad
import Data.Binary
import Data.Bits
import Data.IORef
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List
import Data.Time
import Network.Socket
import Network.Socket.ByteString (recvFrom, sendAll)

import Text.Printf
import System.Random
import System.Environment (getArgs)
import System.Exit
import System.Posix

import ICMP


defaultTimeoutus :: Timeout
defaultTimeoutus = 4000 * 1000

defaultTimeoutMs :: Timeout
defaultTimeoutMs = 4000

data Message
  = MsgPingSent (Word32, UTCTime)
  | MsgPingReceived (Word32, UTCTime, SockAddr)

type RefId    = Word32
type SentTime = UTCTime
type RecvTime = UTCTime
type Timeout  = Int

data PingResult
  = Received
  | TimedOut
  deriving (Eq, Show)

data PingRef = PingRef
  { refId      :: Word32 -- ident << 16 | seqNum
  -- , packet  :: PingPacket
  , sentTime   :: UTCTime
  , resultTime :: UTCTime
  , result     :: PingResult
  } deriving (Eq, Show)

data PingSent = PingSent
  { sentRefId       :: RefId
  , time            :: SentTime
  , timeoutThreadId :: ThreadId
  } deriving (Eq, Show)

data PingStats = PingStats
  { countSent       :: Int
  , countRecv       :: Int
  , countTimeout    :: Int
  , countSuccess    :: Int
  , pctSuccess      :: Double
  , minRoundTrip    :: Double
  , avgRoundTrip    :: Double
  , maxRoundTrip    :: Double
  , stdDevRoundTrip :: Double
  , roundTripTimes  :: [Double]
  } deriving (Eq, Show)

initialStats :: PingStats
initialStats = PingStats
  { countSent       = 0
  , countRecv       = 0
  , countTimeout    = 0
  , countSuccess    = 0
  , pctSuccess      = 0.0
  , minRoundTrip    = fromIntegral defaultTimeoutMs
  , avgRoundTrip    = 0.0
  , maxRoundTrip    = 0.0
  , stdDevRoundTrip = 0.0
  , roundTripTimes  = []
  }

showStats :: PingStats -> String
showStats PingStats { .. } =
  --- 8.8.8.8 ping statistics ---
  -- 3 packets transmitted, 3 received, 0% packet loss, time 2002ms
  -- rtt min/avg/max/mdev = 13.288/13.320/13.354/0.027 ms
  show countSent <> " packets transmitted"
    <> ", " <> show countRecv <> " received"
    <> ", " <> show ((countSent - countSuccess) `div` countSent * 100) <> "% packet loss"
    <> "\n"
    <> "rtt min/avg/max/mdev = "
    <> printf "%.3f/%.3f/%.3f/%.3f ms"
         minRoundTrip
         avgRoundTrip
         maxRoundTrip
         stdDevRoundTrip

calcStat :: PingStats -> PingRef -> PingStats
calcStat accStat ping =
  case result ping of
    Received ->
      let
        countSuccess' = countSuccess accStat + 1
        countRecv'    = countRecv accStat + 1
        countSent'    = countSent accStat + 1
        pctSuccess'   = 100.0 * fromIntegral countRecv' / fromIntegral countSent'

        tripTime      = pingDiffMs ping
        minRoundTrip' = min (minRoundTrip accStat) tripTime
        maxRoundTrip' = max (maxRoundTrip accStat) tripTime
        countSuccessDbl = fromIntegral countSuccess'
        avgRoundTrip' = (
            avgRoundTrip accStat * (countSuccessDbl - 1)
            + tripTime
          ) / countSuccessDbl

        roundTripTimes' = tripTime : roundTripTimes accStat
        sumOfSquares = sum $ map (\x ->
            (avgRoundTrip' - x) * (avgRoundTrip' - x)
          ) roundTripTimes'
        stdDevRoundTrip' = sqrt $ sumOfSquares / countSuccessDbl
      in
        accStat
          { countSuccess    = countSuccess'
          , countRecv       = countRecv'
          , countSent       = countSent'
          , pctSuccess      = pctSuccess'
          , minRoundTrip    = minRoundTrip'
          , maxRoundTrip    = maxRoundTrip'
          , avgRoundTrip    = avgRoundTrip'
          , stdDevRoundTrip = stdDevRoundTrip'
          , roundTripTimes  = roundTripTimes'
          }
    TimedOut ->
      let
        countTimeout' = countTimeout accStat + 1
        countSent'    = countSent accStat + 1
      in accStat
        { countTimeout = countTimeout'
        , countSent = countSent'
        }

calcStats :: IORef [PingRef] -> IORef [PingSent] -> IO [PingStats]
calcStats refs sent = do
  refs' <- readIORef refs
  sent' <- readIORef sent
  return $ scanl calcStat
    (calcStat (initialStats { countSent = length sent' }) (head refs')) (tail refs')

-- combines id and seqNum to form a unique refId
mkRefId :: Word16 -> Word16 -> Word32
mkRefId ident seqNum = fromIntegral ident .<<. 16 .|. fromIntegral seqNum

pingDiffMs :: PingRef -> Double
pingDiffMs (PingRef { sentTime, resultTime }) = 1000.0 *
  (realToFrac $ nominalDiffTimeToSeconds (diffUTCTime resultTime sentTime) :: Double)

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
    writeChan chan $ MsgPingSent (mkRefId ident seqNum, now)

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
  writeChan chan $ MsgPingReceived (refId', recvTime, sockAddr)
  putStrLn ""

removeFromSent :: RefId -> IORef [PingSent] -> IO [PingSent]
removeFromSent refId' sent = do
  (matches, noMatch) <- readIORef sent >>= \sent' ->
     return $ partition (\(PingSent refId _ _) -> refId == refId') sent'
  writeIORef sent noMatch
  return matches

printStats :: [PingStats] -> IO ()
printStats stats = do
  putStrLn "All:"
  putStrLn $ showStats (last stats)
  putStrLn ""
  putStrLn "Last 10:"
  putStrLn $ showStats $ last $ take 10 stats
  putStrLn ""

pingMaster :: Chan Message -> IO ()
pingMaster chan = do
  -- TODO: wrapper around each? or just refs?
  -- e.g. addNewRef refs newPingRef -- return the new value?
  stats <- newIORef [initialStats] :: IO (IORef [PingStats])
  refs  <- newIORef [] :: IO (IORef [PingRef])
  sent  <- newIORef [] :: IO (IORef [PingSent])

  forever $ do
    readChan chan >>= \case
      (MsgPingSent (refId', sentTime)) -> do
        putStrLn $ "Sent: " <> show refId'

        -- start timeout timer
        timeoutThreadId <- forkIO $ do
          threadDelay defaultTimeoutus
          putStrLn $ show refId' <> " timed out"
          getCurrentTime >>= \now ->
            modifyIORef refs $ \refs' ->
              PingRef refId' sentTime now TimedOut : refs'
          _matches <- removeFromSent refId' sent
          newStats <- calcStats refs sent
          putStrLn $ showStats (last newStats)

        modifyIORef sent $ \sent' ->
          sent' <> [PingSent refId' sentTime timeoutThreadId]
        return ()

      (MsgPingReceived (refId', recvTime', sockAddr)) -> do
        -- putStrLn $ "Recv: refId " <> show refId' <> " @ " <> show recvTime'
        -- NOTE: this will match pings sent from other ping utilities
        putStrLn $ "Received reply for refId "
          <> show refId'
          <> " from: " <> show sockAddr

        matches <- removeFromSent refId' sent
        case matches of
          []        -> putStrLn $ "DEBUG: No match for seqNum: " <> show refId'
          (match:_) -> do
            let (PingSent sentId sentTime timeoutThreadId) = match
            killThread timeoutThreadId

            let pingRef = PingRef sentId sentTime recvTime' Received
            putStrLn $ printf "%.1f ms\n" $ pingDiffMs pingRef

            -- update refs
            refs' <- readIORef refs
            let newRefs = pingRef : refs'
            -- mapM_ (print . pingDiffMs) newRefs
            writeIORef refs newRefs

            -- update stats
            newStats <- calcStats refs sent
            writeIORef stats newStats
            printStats newStats

intervalSec :: Int
intervalSec = 1000 * 5000

randomID :: IO Word16
randomID = do
  gen <- newStdGen
  return $ 65535 * (head $ randoms gen :: Word16)

main :: IO ()
main = do
  sigHandler <- newEmptyMVar

  -- TODO: sigint to show final stats and exit
  -- _ <- installHandler sigINT ...

  myIdent <- randomID

  target <- head <$> getArgs

  addr <- head <$>
    getAddrInfo
      (Just defaultHints
          { addrFlags      = [AI_ADDRCONFIG]
          , addrSocketType = Raw
          , addrProtocol   = 1
      })
      (Just target)
      Nothing
  print addr

  chan <- newChan :: IO (Chan Message)

  sock <- openSocket addr
  print sock
  print $ addrAddress addr
  connect sock (addrAddress addr)

  let pings =
        map (\seqNum -> do
          let payload = "your mom goes to college" :: BS.ByteString
          putStrLn $ "Sending " <> show (BS.length payload) <> " bytes to " <> target
          sendPing sock chan myIdent seqNum payload
          threadDelay intervalSec
        ) [0..]

  threadsDone <- newEmptyMVar
  _listenThreadId <- forkFinally
    (pingListen sock chan)
    (\_ -> putMVar threadsDone myThreadId)
  _masterThreadId <- forkIO $ pingMaster chan

  -- when sigint handler is installed properly
  _pingThreadId <- forkIO $ sequence_ pings
  putStrLn "pinging..."

  -- TODO:
  takeMVar sigHandler
