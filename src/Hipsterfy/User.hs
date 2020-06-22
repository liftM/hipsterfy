module Hipsterfy.User
  ( createOAuthRedirect,
    User (..),
    createUser,
    getUserByID,
    getUserBySpotifyID,
    getUserByFriendCode,
    getCredentials,
    setUserFollowUpdating,
    getFollowedArtists,
  )
where

import Control.Monad.Except (liftEither, throwError)
import Data.Time (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Connection, Only (Only), Query, ToRow, execute, query)
import Hipsterfy.Spotify
  ( SpotifyArtist,
    SpotifyUser (..),
    getSpotifyUser,
  )
import Hipsterfy.Spotify.Auth
  ( Scope,
    SpotifyApp,
    SpotifyCredentials (..),
    authorizationURL,
    requestAccessTokenFromAuthorizationCode,
    requestAccessTokenFromRefreshToken,
  )
import Relude
import Test.RandomStrings (randomASCII, randomWord)

data User = User
  { userID :: Int,
    friendCode :: Text,
    spotifyUserID :: Text,
    spotifyUserName :: Text,
    spotifyCredentials :: SpotifyCredentials
  }

-- Signup and creation.

createOAuthRedirect :: (MonadIO m) => SpotifyApp -> Connection -> [Scope] -> m LText
createOAuthRedirect app conn scopes = do
  oauthState <- liftIO $ toText <$> randomWord randomASCII 20
  now <- liftIO getCurrentTime
  void $ liftIO $ execute conn "INSERT INTO spotify_oauth_request (oauth2_state, created_at) VALUES (?, ?)" (oauthState, now)
  return $ authorizationURL app scopes oauthState

createUser :: (MonadIO m) => SpotifyApp -> Connection -> Text -> Text -> m (Either Text User)
createUser app conn authCode oauthState =
  runExceptT $ do
    -- Validate the OAuth state, then delete that state.
    oauthStateRows <- liftIO (query conn "SELECT oauth2_state FROM spotify_oauth_request WHERE oauth2_state = ?" (Only oauthState) :: IO [Only Text])
    spotifyCredentials <- liftEither =<< case oauthStateRows of
      [_] -> do
        void $ liftIO $ execute conn "DELETE FROM spotify_oauth_request WHERE oauth2_state = ?" (Only oauthState)
        Right <$> requestAccessTokenFromAuthorizationCode app authCode
      _ -> throwError "invalid OAuth request state"

    -- Exchange OAuth authorization code for credentials.
    spotifyUser@SpotifyUser {spotifyUserID, spotifyUserName} <- liftIO $ getSpotifyUser spotifyCredentials

    -- Construct a user if one doesn't already exist.
    user <- lift $ getUserBySpotifyID conn spotifyUserID
    case user of
      Just u -> return u
      Nothing -> do
        friendCode <- liftIO $ toText <$> randomWord randomASCII 20
        userRows <- liftIO $ insertUser friendCode spotifyUser spotifyCredentials
        case userRows of
          [Only userID] -> return $ User {userID, friendCode, spotifyUserID, spotifyUserName, spotifyCredentials}
          _ -> error "impossible: insert of single User returned zero or more than 1 row"
  where
    insertUser :: Text -> SpotifyUser -> SpotifyCredentials -> IO [Only Int]
    insertUser friendCode SpotifyUser {spotifyUserID, spotifyUserName} SpotifyCredentials {accessToken, expiration, refreshToken} = do
      now <- getCurrentTime
      query
        conn
        "INSERT INTO hipsterfy_user\
        \ (friend_code, spotify_user_id, spotify_user_name, spotify_access_token, spotify_access_token_expiration, spotify_refresh_token, created_at)\
        \ VALUES (?, ?, ?, ?, ?, ?, ?)\
        \ RETURNING id"
        ( friendCode,
          spotifyUserID,
          spotifyUserName,
          accessToken,
          expiration,
          refreshToken,
          now
        )

-- Retrieval.

getUserByID :: (MonadIO m) => Connection -> Int -> m (Maybe User)
getUserByID conn userID =
  getUser
    conn
    "SELECT\
    \ id, friend_code,\
    \ spotify_user_id, spotify_user_name, spotify_access_token, spotify_access_token_expiration, spotify_refresh_token\
    \ FROM hipsterfy_user\
    \ WHERE id = ?"
    (Only userID)

getUserBySpotifyID :: (MonadIO m) => Connection -> Text -> m (Maybe User)
getUserBySpotifyID conn spotifyUserID =
  getUser
    conn
    "SELECT\
    \ id, friend_code,\
    \ spotify_user_id, spotify_user_name, spotify_access_token, spotify_access_token_expiration, spotify_refresh_token\
    \ FROM hipsterfy_user\
    \ WHERE spotify_user_id = ?"
    (Only spotifyUserID)

getUserByFriendCode :: (MonadIO m) => Connection -> Text -> m (Maybe User)
getUserByFriendCode conn friendCode =
  getUser
    conn
    "SELECT\
    \ id, friend_code,\
    \ spotify_user_id, spotify_user_name, spotify_access_token, spotify_access_token_expiration, spotify_refresh_token\
    \ FROM hipsterfy_user\
    \ WHERE friend_code = ?"
    (Only friendCode)

getUser :: (MonadIO m, ToRow q) => Connection -> Query -> q -> m (Maybe User)
getUser conn sql params = do
  -- TODO: is there a way we can compose the SQL query, so we can specify the
  -- columns and just take the `WHERE` clause as an argument?
  rows <- liftIO $ query conn sql params
  return $ case rows of
    [ ( userID,
        friendCode,
        spotifyUserID,
        spotifyUserName,
        accessToken,
        expiration,
        refreshToken
        )
      ] ->
        Just $
          User
            { userID,
              friendCode,
              spotifyUserID,
              spotifyUserName,
              spotifyCredentials = SpotifyCredentials {accessToken, refreshToken, expiration}
            }
    _ -> Nothing

-- Operations.

getCredentials :: (MonadIO m) => SpotifyApp -> Connection -> User -> m SpotifyCredentials
getCredentials app conn User {userID, spotifyCredentials} = do
  now <- liftIO getCurrentTime
  if now > expiration spotifyCredentials
    then do
      refreshedCreds <- requestAccessTokenFromRefreshToken app spotifyCredentials
      liftIO $ updateCreds refreshedCreds
      return refreshedCreds
    else return spotifyCredentials
  where
    updateCreds :: SpotifyCredentials -> IO ()
    updateCreds SpotifyCredentials {accessToken, refreshToken, expiration} =
      void $
        execute
          conn
          "UPDATE hipsterfy_user\
          \ SET spotify_access_token = ?, spotify_access_token_expiration = ?, spotify_refresh_token = ?\
          \ WHERE id = ?"
          ( accessToken,
            expiration,
            refreshToken,
            userID
          )

setUserFollowUpdating :: (MonadIO m) => Connection -> User -> UTCTime -> Int -> m ()
setUserFollowUpdating conn user started total = undefined

data UpdateStatus = UpdatedAt UTCTime | InProgress Int Int

getFollowedArtists :: (MonadIO m) => Connection -> User -> m (UpdateStatus, [SpotifyArtist])
getFollowedArtists conn user = undefined
