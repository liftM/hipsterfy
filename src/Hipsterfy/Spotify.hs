module Hipsterfy.Spotify
  ( SpotifyUser (..),
    SpotifyUserID (..),
    getSpotifyUser,
    SpotifyArtist (..),
    SpotifyArtistID (..),
    getFollowedSpotifyArtists,
    getSpotifyArtistsOfSavedTracks,
    getSpotifyArtistsOfSavedAlbums,
    SpotifyArtistInsights (..),
    getSpotifyArtistInsights,
  )
where

import Control.Lens ((.~))
import Data.Aeson ((.:), (.:?), FromJSON (..), ToJSON, withObject)
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import Hipsterfy.Spotify.API
  ( SpotifyPagedResponse,
    requestAsJSON,
    requestSpotifyAPI,
    requestSpotifyAPIPages,
    requestSpotifyAPIPages',
    spotifyAPIURL,
  )
import Hipsterfy.Spotify.Auth (AnonymousBearerToken (..), SpotifyCredentials (..))
import Network.Wreq (defaults, getWith, header)
import Opaleye (SqlText)
import Opaleye.Internal.RunQuery (DefaultFromField)
import Relude

-- Spotify users.

newtype SpotifyUserID = SpotifyUserID Text
  deriving (Show, Eq, Ord, Generic, FromJSON, ToJSON, IsString, ToString, ToField, FromField, DefaultFromField SqlText)

data SpotifyUser = SpotifyUser
  { spotifyUserID :: SpotifyUserID,
    spotifyUserName :: Text
  }

instance FromJSON SpotifyUser where
  parseJSON = withObject "user" $ \o ->
    SpotifyUser <$> o .: "id" <*> o .: "display_name"

getSpotifyUser :: (MonadIO m) => SpotifyCredentials -> m SpotifyUser
getSpotifyUser creds = requestSpotifyAPI creds $ spotifyAPIURL <> "/me"

-- Spotify artists.

newtype SpotifyArtistID = SpotifyArtistID Text
  deriving (Show, Eq, Ord, Generic, FromJSON, ToJSON, IsString, ToString, ToField, FromField, DefaultFromField SqlText)

instance Hashable SpotifyArtistID

data SpotifyArtist = SpotifyArtist
  { spotifyArtistID :: SpotifyArtistID,
    spotifyURL :: Text,
    name :: Text
  }
  deriving (Show, Generic)

instance Hashable SpotifyArtist

instance Eq SpotifyArtist where
  (==) = (==) `on` spotifyArtistID

instance Ord SpotifyArtist where
  compare = comparing spotifyArtistID

instance FromJSON SpotifyArtist where
  parseJSON = withObject "artist" $ \o -> do
    spotifyArtistID <- o .: "id"
    urls <- o .: "external_urls"
    spotifyURL <- withObject "external_urls" (.: "spotify") urls
    name <- o .: "name"
    return SpotifyArtist {spotifyArtistID, spotifyURL, name}

-- Loading followed artists.

newtype SpotifyFollowedArtistsResponse = SpotifyFollowedArtistsResponse
  { artists :: SpotifyPagedResponse SpotifyArtist
  }
  deriving (Show, Generic)

instance FromJSON SpotifyFollowedArtistsResponse

getFollowedSpotifyArtists :: (MonadIO m) => SpotifyCredentials -> m [SpotifyArtist]
getFollowedSpotifyArtists creds =
  requestSpotifyAPIPages' creds artists $ spotifyAPIURL <> "/me/following?type=artist&limit=50"

newtype SpotifyTrack = SpotifyTrack
  { spotifyTrackArtists :: [SpotifyArtist]
  }

instance FromJSON SpotifyTrack where
  parseJSON = withObject "track item" $ \item -> do
    track <- item .: "track"
    spotifyTrackArtists <- withObject "track" (\t -> (t .: "artists") >>= parseJSON) track
    return SpotifyTrack {..}

getSpotifyArtistsOfSavedTracks :: (MonadIO m) => SpotifyCredentials -> m [SpotifyArtist]
getSpotifyArtistsOfSavedTracks creds =
  (return . hashNub . concatMap spotifyTrackArtists) =<< requestSpotifyAPIPages creds (spotifyAPIURL <> "/me/tracks?limit=50")

newtype SpotifyAlbum = SpotifyAlbum
  { spotifyAlbumArtists :: [SpotifyArtist]
  }

instance FromJSON SpotifyAlbum where
  parseJSON = withObject "album item" $ \item -> do
    album <- item .: "album"
    spotifyAlbumArtists <- withObject "album" (\t -> (t .: "artists") >>= parseJSON) album
    return SpotifyAlbum {..}

getSpotifyArtistsOfSavedAlbums :: (MonadIO m) => SpotifyCredentials -> m [SpotifyArtist]
getSpotifyArtistsOfSavedAlbums creds =
  (return . hashNub . concatMap spotifyAlbumArtists) =<< requestSpotifyAPIPages creds (spotifyAPIURL <> "/me/albums?limit=50")

-- Loading artist monthly listeners.

newtype SpotifyArtistInsights = SpotifyArtistInsights
  { monthlyListeners :: Int
  }
  deriving (Show, Eq, Ord)

instance FromJSON SpotifyArtistInsights where
  parseJSON = withObject "artist insights response" $ \res -> do
    insights <- res .: "artistInsights"
    withObject
      "artistInsights"
      ( \o -> do
          listeners <- o .:? "monthly_listeners"
          followers <- o .: "follower_count"
          return $ SpotifyArtistInsights {monthlyListeners = fromMaybe followers listeners}
      )
      insights

getSpotifyArtistInsights :: (MonadIO m) => AnonymousBearerToken -> SpotifyArtistID -> m SpotifyArtistInsights
getSpotifyArtistInsights (AnonymousBearerToken bearerToken) spotifyArtistID =
  requestAsJSON
    $ getWith
      (defaults & header "Authorization" .~ ["Bearer " <> encodeUtf8 bearerToken])
    $ "https://spclient.wg.spotify.com/open-backend-2/v1/artists/" <> toString spotifyArtistID
