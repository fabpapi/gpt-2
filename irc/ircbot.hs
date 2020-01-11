{-# Language OverloadedStrings #-}
{-# Language RecordWildCards #-}
{-# Language FlexibleContexts #-}
{-# Language ScopedTypeVariables #-}

module Main where

import           Control.Applicative
import           Control.Monad.Catch (catch)
import           Control.Exception (SomeException)
import           Control.Concurrent
import           Control.Lens
import           Control.Monad
import           Control.Monad.IO.Class
import qualified Control.Monad.State.Class as S
import           Data.ByteString (ByteString)
import           Data.Foldable
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Time.Clock
import           Data.Time.Format
import           GHC.IO.Handle
import           Network.IRC.CTCP
import           Network.IRC.Client
import           System.IO
import           System.Exit

import           GPT2
import           LogFormat

kChannel :: Text
kChannel = "#lw-gpt"

type Channel = Text

data MyState = MyState {
  _stContext :: Text,
  _stLastWakeup :: Maybe UTCTime,
  _stLastChat :: UTCTime,
  _stHasLink :: Int
  }

stContext f (MyState{..}) = (\_stContext -> MyState {..}) <$> f _stContext
stLastWakeup f (MyState{..}) = (\_stLastWakeup -> MyState {..}) <$> f _stLastWakeup
stLastChat f (MyState{..}) = (\_stLastChat -> MyState {..}) <$> f _stLastChat
stHasLink f (MyState{..}) = (\_stHasLink -> MyState {..}) <$> f _stHasLink

portalSeconds :: NominalDiffTime
portalSeconds = 60 * 60 -- 1 hour

shutupThread :: IRC MyState ()
shutupThread = go False
  where
    go awake = do
      liftIO (threadDelay (1 * 1000000))
      now <- liftIO getCurrentTime
      lastWakeup <- use stLastWakeup
      case lastWakeup of
        Just wk
          | diffUTCTime now wk <= portalSeconds -> go True
        _ -> when awake (send (Privmsg kChannel (Right ("Shutting up...")))) >> go False

extendContext :: Msg -> IRC MyState ()
extendContext msg = do
  let line = formatMsg msg <> "\n"
  stContext %= (<> line)
  when (T.isInfixOf "http" line || T.isInfixOf "\t.g" line || T.isInfixOf "\t.wp" line) $
    stHasLink %= (+1)
  newctx <- use stContext
  liftIO (T.writeFile "context.txt" newctx)

getCanSpeak :: IRC MyState Bool
getCanSpeak = do
  now <- liftIO getCurrentTime
  lastWakeup <- use stLastWakeup
  lastChat <- use stLastChat
  ctx <- use stContext
  case lastWakeup of
    Just wk -> return ((diffUTCTime now wk <= portalSeconds)
                       && (diffUTCTime now lastChat >= 15)
                       && T.isSuffixOf "\n" ctx)
    Nothing -> return False

sampleThread :: IRC MyState ()
sampleThread = forever (go
                        `catch` (\(e :: GPT2.Timeout) -> sendLine kChannel "Timed out")
                        `catch` (\(e :: SomeException) -> liftIO (print e)))
  where
    feepbot = do
      hasLink <- use stHasLink
      guard (hasLink > 0)
      now <- liftIO getCurrentTime
      ctx <- use stContext
      let
        prompt = Msg (formatTimestamp now) "feepbot" ""
        go = do
          (newctx, msg) <- sampleMessageWithPrompt ctx prompt
          if ("Wikipedia" `T.isSuffixOf` mtext msg) then
            putStrLn ("redrawing " ++ show msg) >> go
            else
            return (newctx, msg)
      (newctx, msg) <- liftIO go
      stContext .= (newctx <> formatMsg msg <> "\n")
      sendMsg kChannel msg
      stHasLink %= subtract 1
      stLastChat .= now

    normal = do
      guard =<< getCanSpeak
      ctx <- use stContext
      (newctx, msg) <- liftIO (sampleMessage ctx)
      ctx' <- use stContext
      guard (ctx == ctx') -- try again if someone said something in the mean time
      stContext .= newctx

      now <- liftIO getCurrentTime
      let msg' = msg{mtime = formatTimestamp now}
      sendMsg kChannel msg'
      extendContext msg'
      stLastChat .= now

    go = do
      liftIO (threadDelay (1 * 1000000))
      feepbot <|> normal <|> pure()

noping :: Text -> Text
noping us
  | T.null us = us
  | otherwise = T.take 1 us <> "\x2060" <> T.drop 1 us

cleanzwsp :: Text -> Text
cleanzwsp = T.filter (/= '\x2060')

sendMsg :: Channel -> Msg -> IRC MyState ()
sendMsg chan Msg{..} = sendLine chan ("<" <> noping muser <> "> " <> mtext)

sendLine :: Channel -> Text -> IRC MyState ()
sendLine chan msg
  | totalLength > lengthLimit = do
      send (Privmsg chan (Right $ T.dropEnd overage msg <> "…"))
      sendLine chan ("…" <> T.takeEnd overage msg)
  | otherwise = send (Privmsg chan (Right msg))
  where
    lengthLimit = 510 - 50
    totalLength = T.length ("PRIVMSG " <> chan <> " :" <> msg)
    overage = totalLength - lengthLimit + 3

gwernpaste :: Channel -> Text -> IRC MyState ()
gwernpaste chan prompt = void $ fork (go
                                      `catch` (\(e :: GPT2.Timeout) -> sendLine kChannel "Timed out")
                                      `catch` (\(e :: SomeException) -> liftIO (print e)))
  where
    go = do
      orig_ctx <- pure "" -- use stContext
      ls <- liftIO (sampleGwernpaste orig_ctx prompt)
      for_ ls $ \line -> do
        sendMsg chan line
        extendContext line

completion :: Channel -> Text -> Text -> IRC MyState ()
completion chan user prompt = do
  ctx <- use stContext
  now <- liftIO getCurrentTime
  let lctx = if T.isPrefixOf "<" prompt && T.isInfixOf ">" prompt then
               let user' = T.takeWhile (/= '>') . T.drop 1 $ prompt
                   prompt' = T.drop 2 . T.dropWhile (/= '>') $ prompt
               in Msg (formatTimestamp now) user' prompt'
             else
               Msg (formatTimestamp now) user prompt
  (newctx, msg) <- liftIO (sampleMessageWithPrompt ctx lctx)
  sendMsg chan msg
  extendContext msg

getChannel :: Source Text -> Channel
getChannel (Channel ch u) = ch
getChannel (User u) = u

getUser :: Source Text -> Text
getUser (Channel ch u) = u
getUser (User u) = u

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering

  [nick, pass] <- T.splitOn "/" <$> T.readFile "identity.txt"

  let conn = tlsConnection (WithDefaultConfig "chat.freenode.net" 7000)
             & username .~ nick
             & realname .~ nick
             & password .~ Just pass
             & logfunc .~ stdoutLogger
             & timeout .~ 24 * 3600
  let cfg  = defaultInstanceConfig "gpt2"
             & channels .~ []
             & handlers %~ (myhandlers ++)

      myhandlers = [
        EventHandler (matchType _Notice) handleNotice,
        EventHandler (matchType _Privmsg) handleMessage
        ]

      handleNotice (User "NickServ") (_, Right msg)
        | T.isPrefixOf "You are now identified" msg = send (Join kChannel)
          >> void (fork shutupThread >> fork sampleThread)
      handleNotice _ _ = pure()

      handleMessage :: Source Text
                         -> (Text, Either CTCPByteString Text)
                         -> IRC MyState ()
      handleMessage _ (_, Right "gpt2: go away") =
        stLastWakeup .= Nothing
      handleMessage _ (_, Right "gpt2: shut up") =
        stLastWakeup .= Nothing
      handleMessage _ (_, Right "gpt2: come back") = do
        now <- liftIO getCurrentTime
        stLastWakeup .= Just now
      handleMessage _ (_, Right "gpt2: wake up") = do
        now <- liftIO getCurrentTime
        stLastWakeup .= Just now
      handleMessage src (_, Right "@gwernpaste") = gwernpaste (getChannel src) ""
      handleMessage src (_, Right "@clear") = do
        stContext .= "\n"
        sendLine (getChannel src) "Forgotten."
      handleMessage _ (_, Right "@reload") = do
        disconnect
        liftIO exitSuccess
      handleMessage src (_, Right msg)
        | T.isPrefixOf "@gwernpaste " msg
        = gwernpaste (getChannel src) (T.drop (T.length "@gwernpaste ") msg)
      handleMessage src (_, Right msg)
        | T.isPrefixOf "@complete " msg
        = completion (getChannel src) (getUser src) (cleanzwsp $ T.drop (T.length "@complete ") msg)
      handleMessage (Channel ch u) (_, Right msg)
        | ch == kChannel
        = do now <- liftIO getCurrentTime
             let timestamp = formatTimestamp now
             extendContext (Msg timestamp u (cleanzwsp msg))
      handleMessage s m = liftIO (print (s,m))

  now <- getCurrentTime
  oldctx <- T.readFile "context.txt" <|> return ""
  runClient conn cfg (MyState oldctx Nothing now 0)
