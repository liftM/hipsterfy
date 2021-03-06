module Hipsterfy.Jobs.UpdateArtist
  ( handleUpdateArtist,
    enqueueUpdateArtist,
    updateArtistQueue,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Faktory.Job (perform, queue)
import Faktory.Settings (Queue (Queue))
import Hipsterfy.Application (Config (..), Faktory (..), MonadApp)
import Hipsterfy.Artist (Artist (..), ArtistID, getArtistByID, refreshArtistInsights, setUpdateCompleted, setUpdateSubmitted)
import Hipsterfy.Jobs (UpdateStatus (..), infoToStatus)
import Hipsterfy.Spotify.Auth (getAnonymousBearerToken)
import Relude

updateArtistQueue :: Queue
updateArtistQueue = Queue "update-artist"

newtype UpdateArtistJob = UpdateArtistJob
  { artistID :: ArtistID
  }
  deriving (Generic)

instance FromJSON UpdateArtistJob

instance ToJSON UpdateArtistJob

enqueueUpdateArtist :: (MonadApp m) => ArtistID -> m ()
enqueueUpdateArtist artistID = do
  Config {faktory = Faktory {..}} <- ask
  maybeArtist <- getArtistByID artistID
  Artist {updateJobInfo} <- case maybeArtist of
    Just artist -> return artist
    Nothing -> error $ "enqueueUpdateArtist: could not find artist with ID " <> show artistID
  status <- infoToStatus updateJobInfo
  case status of
    NeedsUpdate -> do
      setUpdateSubmitted artistID
      void $ liftIO $ perform (queue updateArtistQueue) client UpdateArtistJob {artistID}
    _ -> pass

handleUpdateArtist :: (MonadApp m) => UpdateArtistJob -> m ()
handleUpdateArtist UpdateArtistJob {..} = do
  maybeArtist <- getArtistByID artistID
  artist <- case maybeArtist of
    Just a -> return a
    Nothing -> error $ "handleUpdateArtist: could not find artist with ID " <> show artistID
  bearerToken <- getAnonymousBearerToken
  _ <- refreshArtistInsights bearerToken artist
  setUpdateCompleted artistID
