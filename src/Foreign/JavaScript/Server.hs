{-# LANGUAGE RecordWildCards, OverloadedStrings #-}
module Foreign.JavaScript.Server (
    httpComm
    ) where

-- import general libraries
import           Control.Concurrent
import qualified Control.Concurrent.Chan    as Chan
import qualified Control.Exception          as E
import           Control.Monad
import           Data.ByteString                    (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Text
import qualified Safe                       as Safe
import           System.Environment
import           System.FilePath

-- import web libraries
import           Data.Aeson                             ((.=))
import qualified Data.Aeson                    as JSON
import qualified Network.WebSockets            as WS
import qualified Network.WebSockets.Snap       as WS
import           Snap.Core
import qualified Snap.Http.Server              as Snap
import           Snap.Util.FileServe

-- import internal modules
import Foreign.JavaScript.Resources
import Foreign.JavaScript.Types

{-----------------------------------------------------------------------------
    HTTP Server using WebSockets
------------------------------------------------------------------------------}
-- | Run a HTTP server that creates a 'Comm' channel.
httpComm :: Config -> (Comm -> IO ()) -> IO ()
httpComm Config{..} worker = do
    env <- getEnvironment
    let portEnv = Safe.readMay =<< Prelude.lookup "PORT" env
    let addrEnv = Safe.readMay =<< Prelude.lookup "ADDR" env
    
    let config = Snap.setPort      (maybe defaultPort id (jsPort `mplus` portEnv))
               $ Snap.setBind      (maybe defaultAddr id (jsAddr `mplus` addrEnv))
               $ Snap.setErrorLog  (Snap.ConfigIoLog jsLog)
               $ Snap.setAccessLog (Snap.ConfigIoLog jsLog)
               $ Snap.defaultConfig
    Snap.httpServe config . route $
        routeResources jsCustomHTML jsStatic
        ++ routeWebsockets worker

-- | Route the communication between JavaScript and the server
routeWebsockets :: (Comm -> IO void) -> Routes
routeWebsockets worker = [("websocket", response)]
    where
    response = WS.runWebSocketsSnap $ \ws -> void $ do
        comm <- communicationFromWebSocket ws
        worker comm
        -- error "Foreign.JavaScript: unreachable code path."

-- | Create 'Comm' channel from WebSocket request.
communicationFromWebSocket :: WS.PendingConnection -> IO Comm
communicationFromWebSocket request = do
    connection    <- WS.acceptRequest request
    communication <- newComm

    -- write data (in another thread)
    sendData <- forkIO . forever $ do
        x <- Chan.readChan (commOut communication)
        -- see note [ServerMsg strictness]
        WS.sendTextData connection . JSON.encode $ x

    -- read data
    let readData = do
            input <- WS.receiveData connection
            case input of
                "ping" -> WS.sendTextData connection . LBS.pack $ "pong"
                "quit" -> E.throw WS.ConnectionClosed
                input  -> case JSON.decode input of
                    Just x   -> Chan.writeChan (commIn communication) x
                    Nothing  -> error $
                        "Foreign.JavaScript: Couldn't parse JSON input"
                        ++ show input
    
    forkIO $ E.finally (forever readData) $ do   -- we're done here
        killThread sendData                      -- kill sending thread
        writeChan (commIn communication) $
            JSON.object [ "tag" .= ("Quit" :: Text) ] -- write Quit event

    return communication

{-----------------------------------------------------------------------------
    Resources
------------------------------------------------------------------------------}
type Routes = [(ByteString, Snap ())]

routeResources :: Maybe FilePath -> Maybe FilePath -> Routes
routeResources customHTML staticDir =
    fixHandlers noCache $
        static ++
        [("/"            , root)
        ,("/haskell.js"  , writeTextMime jsDriverCode  "application/javascript")
        ,("/haskell.css" , writeTextMime cssDriverCode "text/css")
        ]
    where
    fixHandlers f routes = [(a,f b) | (a,b) <- routes]
    noCache h = modifyResponse (setHeader "Cache-Control" "no-cache") >> h
    
    static = maybe [] (\dir -> [("/static", serveDirectory dir)]) staticDir
    
    root = case customHTML of
        Just file -> case staticDir of
            Just dir -> serveFile (dir </> file)
            Nothing  -> logError "Foreign.JavaScript: Cannot use jsCustomHTML file without jsStatic"
        Nothing   -> writeTextMime defaultHtmlFile "text/html"

writeTextMime text mime = do
    modifyResponse (setHeader "Content-type" mime)
    writeText text
