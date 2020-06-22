module Hipsterfy.Server (runServer, server, Options (..)) where

import Control.Monad.Except (throwError)
import qualified Control.Monad.Parallel as Parallel (mapM)
import Data.Time (getCurrentTime)
import Database.PostgreSQL.Simple (Connection, connectPostgreSQL)
import Faktory.Client (Client, newClient)
import Faktory.Settings (ConnectionInfo (..), Queue, Settings (..))
import qualified Faktory.Settings as Faktory (defaultSettings)
import Hipsterfy.Artist (getArtistInsights, getCachedArtistInsights)
import Hipsterfy.Jobs.UpdateUser (enqueueUpdateUser, updateUserQueue)
import Hipsterfy.Pages (accountPage, comparePage, loginPage)
import Hipsterfy.Session (endSession, getSession, startSession)
import Hipsterfy.Spotify
  ( SpotifyArtist,
    SpotifyArtistInsights,
    getFollowedSpotifyArtists,
    getSpotifyArtistsOfSavedAlbums,
    getSpotifyArtistsOfSavedTracks,
  )
import Hipsterfy.Spotify.Auth
  ( AnonymousBearerToken,
    Scope,
    SpotifyApp (..),
    getAnonymousBearerToken,
    scopeUserFollowRead,
    scopeUserLibraryRead,
    scopeUserTopRead,
  )
import Hipsterfy.User (User, createOAuthRedirect, createUser, getCredentials, getFollowedArtists, getUserByFriendCode)
import Network.Wai.Handler.Warp (defaultSettings, setPort)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import Relude
import Web.Scotty (ActionM, ScottyM, html, middleware, param, redirect, scottyOpts)
import qualified Web.Scotty as S
import Web.Scotty.Internal.Types (ActionError (Redirect))

data Options = Options
  { host :: Text,
    port :: Int,
    pgConn :: Text,
    clientID :: Text,
    clientSecret :: Text,
    faktoryHost :: Text,
    faktoryPort :: Int,
    faktoryPassword :: Maybe Text
  }
  deriving (Show)

runServer :: Options -> IO ()
runServer Options {host, port, pgConn, clientID, clientSecret, faktoryHost, faktoryPassword, faktoryPort} = do
  conn <- connectPostgreSQL $ encodeUtf8 pgConn
  updateUserClient <- newClient (settingsForQ updateUserQueue) Nothing

  putStrLn $ "Starting server at: " `mappend` show address
  scottyOpts
    S.Options {verbose = 0, settings = defaultSettings & setPort port}
    $ server spotifyApp updateUserClient conn
  where
    address :: Text
    address = host `mappend` case port of
      80 -> ""
      other -> ":" `mappend` show other
    spotifyApp :: SpotifyApp
    spotifyApp = SpotifyApp {clientID, clientSecret, redirectURI = address <> "/authorize/callback"}
    settingsForQ :: Queue -> Settings
    settingsForQ queue =
      Faktory.defaultSettings
        { settingsQueue = queue,
          settingsConnection =
            ConnectionInfo
              { connectionInfoTls = False,
                connectionInfoHostName = toString faktoryHost,
                connectionInfoPassword = toString <$> faktoryPassword,
                connectionInfoPort = fromInteger $ toInteger faktoryPort
              }
        }

server :: SpotifyApp -> Client -> Connection -> ScottyM ()
server spotifyApp updateUserClient conn = do
  middleware logStdoutDev

  -- Home page. Check cookies to see if logged in.
  -- If not logged in, prompt to authorize.
  -- If logged in, provide friend code input.
  S.get "/" $ do
    user <- getSession conn
    case user of
      Just u -> do
        -- TODO: why is this so slow?
        void $ enqueueUpdateUser updateUserClient u
        (status, followed) <- getFollowedArtists conn u
        insights <- mapM (getCachedArtistInsights conn) followed
        html $ accountPage u (status, zip followed insights)
      Nothing -> html loginPage

  -- Authorization redirect. Generate a new user's OAuth secret and friend code. Redirect to Spotify.
  S.get "/authorize" $ createOAuthRedirect spotifyApp conn spotifyScopes >>= redirect

  -- Authorization callback. Populate a user's Spotify information based on the callback. Set cookies to logged in. Redirect to home page.
  S.get "/authorize/callback" $ do
    -- If a session is already set, then ignore this request.
    session <- getSession conn
    case session of
      Just _ -> throwError $ Redirect "/"
      Nothing -> pass

    -- Obtain access tokens.
    code <- param "code" :: ActionM Text
    oauthState <- param "state" :: ActionM Text
    eitherUser <- createUser spotifyApp conn code oauthState
    user <- case eitherUser of
      Right user -> return user
      Left err -> do
        print err
        throwError $ Redirect "/"

    -- Create a new session.
    startSession conn user

    -- Redirect to dashboard.
    redirect "/"

  -- Compare your artists against a friend code. Must be logged in.
  S.post "/compare" $ do
    -- Require authentication.
    maybeUser <- getSession conn
    user <- case maybeUser of
      Just u -> return u
      Nothing -> throwError $ Redirect "/"

    -- Check that the friend code is valid.
    friendCode <- param "friend-code" :: ActionM Text
    maybeFriend <- getUserByFriendCode conn friendCode
    friend <- case maybeFriend of
      Just f -> return f
      -- TODO: display an error message for invalid friend codes.
      Nothing -> throwError $ Redirect "/"

    -- Load followed artists.
    -- TODO: migrate this to the new `getFollowedArtists.
    -- We should basically never do any API calls on-path to a request - we
    -- should always be using cached values, and account for cache
    -- staleness/unavailability.
    bearerToken <- getAnonymousBearerToken
    yourArtists <- getFollowedArtists' conn bearerToken user
    friendArtists <- getFollowedArtists' conn bearerToken friend

    -- Render page.
    html $ comparePage yourArtists friendArtists

  -- Clear logged in cookies.
  S.get "/logout" $ do
    endSession conn
    redirect "/"
  where
    spotifyScopes :: [Scope]
    spotifyScopes = [scopeUserLibraryRead, scopeUserFollowRead, scopeUserTopRead]
    -- TODO: we should load artists in the background when a user first logs in.
    getFollowedArtists' :: (MonadIO m) => Connection -> AnonymousBearerToken -> User -> m [(SpotifyArtist, SpotifyArtistInsights)]
    getFollowedArtists' conn' bearerToken user = do
      creds <- liftIO $ getCredentials spotifyApp conn' user
      a <- liftIO getCurrentTime
      putStrLn $ "a: " ++ show a
      followedArtists <- snd <$> getFollowedSpotifyArtists creds
      b <- liftIO getCurrentTime
      putStrLn $ "b: " ++ show b
      trackArtists <- snd <$> getSpotifyArtistsOfSavedTracks creds
      c <- liftIO getCurrentTime
      putStrLn $ "c: " ++ show c
      albumArtists <- snd <$> getSpotifyArtistsOfSavedAlbums creds
      d <- liftIO getCurrentTime
      putStrLn $ "d: " ++ show d
      let artists = ordNub $ trackArtists ++ albumArtists ++ followedArtists
      insights <- liftIO $ Parallel.mapM (getArtistInsights conn' bearerToken) artists
      e <- liftIO getCurrentTime
      putStrLn $ "e: " ++ show e
      return $ zip artists insights
