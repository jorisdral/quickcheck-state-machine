{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeOperators         #-}

------------------------------------------------------------------------
-- |
-- Module      :  CrudWebserverFile
-- Copyright   :  (C) 2015, Gabriel Gonzales;
--                (C) 2017, Stevan Andjelkovic
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Stevan Andjelkovic <stevan@advancedtelematic.com>
-- Stability   :  provisional
-- Portability :  non-portable (GHC extensions)
--
-- This module contains the implementation and specification of a simple
-- CRUD webserver that uses files to store data.
--
-- The implementation is based on Gabriel Gonazalez's
-- <https://github.com/Gabriel439/servant-crud servant-crud> repository.
--
-- Readers unfamiliar with the Servant library might want to have a look
-- at its <http://haskell-servant.readthedocs.io/en/stable/ documentation>
-- in case some parts of the implementation of the CRUD
-- webserver are unclear.
--
------------------------------------------------------------------------

module CrudWebserverFile
  ( prop_crudWebserverFile
  , prop_crudWebserverFileParallel
  ) where

import           Control.Concurrent.Async
                   (Async, async, cancel, poll)
import           Control.Monad.IO.Class
                   (liftIO)
import           Control.Monad.Reader
                   (ReaderT, ask, runReaderT)
import           Control.Monad.Trans.Control
                   (MonadBaseControl, liftBaseWith)
import           Data.Functor.Classes
                   (Show1)
import           Data.Map
                   (Map)
import qualified Data.Map                    as Map
import           Data.Text
                   (Text)
import qualified Data.Text.IO                as Text
import           Network.HTTP.Client
                   (defaultManagerSettings, newManager)
import qualified Network.Wai.Handler.Warp    as Warp
import           Servant
                   ((:>), Capture, Delete, Get, JSON, Put, ReqBody)
import           Servant
                   ((:<|>)(..), Proxy(..))
import           Servant.Client
                   (BaseUrl(..), Client, ClientEnv(..), Scheme(..),
                   client, runClientM)
import           Servant.Server
                   (Server, serve)
import qualified System.Directory            as Directory
import           Test.QuickCheck
                   (Gen, Property, arbitrary, elements, frequency,
                   shrink, (===))
import           Test.QuickCheck.Instances
                   ()

import           Test.StateMachine

------------------------------------------------------------------------

-- | A `PUT` request against `/:file` with a `JSON`-encoded request body
type PutFile =
    Capture "file" FilePath :> ReqBody '[JSON] Text :> Put '[JSON] ()

-- | A `GET` request against `/:file` with a `JSON`-encoded response body
type GetFile =
    Capture "file" FilePath :> Get '[JSON] Text

-- | A `DELETE` request against `/:file`
type DeleteFile =
    Capture "file" FilePath :> Delete '[JSON] ()

{-| The type of our REST API

    The server uses this to ensure that each API endpoint's handler has the
    correct type

    The client uses this to auto-generate API bindings
-}
type API =   PutFile
        :<|> GetFile
        :<|> DeleteFile

------------------------------------------------------------------------

-- | Handler for the `PutFile` endpoint
putFile :: Server PutFile
putFile file contents = liftIO (Text.writeFile file contents)

-- | Handler for the `GetFile` endpoint
getFile :: Server GetFile
getFile file = liftIO (Text.readFile file)

-- | Handler for the `DeleteFile` endpoint
deleteFile :: Server DeleteFile
deleteFile file = liftIO (Directory.removeFile file)

-- | Handler for the entire REST `API`
server :: Server API
server = putFile
    :<|> getFile
    :<|> deleteFile

-- | Serve the `API` on port 8080
runServer :: IO ()
runServer = Warp.run 8080 (serve (Proxy :: Proxy API) server)

------------------------------------------------------------------------

-- | Autogenerated API binding for the endpoints
putFileC    :: Client PutFile
getFileC    :: Client GetFile
deleteFileC :: Client DeleteFile

putFileC :<|> getFileC :<|> deleteFileC = client (Proxy :: Proxy API)

------------------------------------------------------------------------

data Action (v :: * -> *) :: * -> * where
  PutFile    :: FilePath -> Text -> Action v ()
  GetFile    :: FilePath ->         Action v Text
  DeleteFile :: FilePath ->         Action v ()

deriving instance Show1 v => Show (Action v resp)

------------------------------------------------------------------------

newtype Model (v :: * -> *) = Model (Map FilePath Text)
  deriving (Eq, Show)

initModel :: Model v
initModel = Model Map.empty

preconditions :: Precondition Model Action
preconditions (Model m) act = case act of
  PutFile    _ _  -> True
  GetFile    file -> Map.member file m
  DeleteFile file -> Map.member file m

transitions :: Transition Model Action
transitions (Model m) act _ = Model $ case act of
  PutFile    file content -> Map.insert file content m
  GetFile    _            -> m
  DeleteFile file         -> Map.delete file m

postconditions :: Postcondition Model Action
postconditions (Model m) act resp =
  let Model m' = transitions (Model m) act (Concrete resp)
  in case act of
    PutFile    file content -> Map.lookup file m' === Just content
    GetFile    file         -> Map.lookup file m  === Just resp
    DeleteFile file         -> Map.lookup file m' === Nothing

------------------------------------------------------------------------

genFilePath :: Gen FilePath
genFilePath = elements ["apa.txt", "bepa.txt"]

generator :: Generator Model Action
generator (Model m)
  | Map.null m = Untyped <$> (PutFile <$> genFilePath <*> arbitrary)
  | otherwise  = frequency
    [ (3, Untyped <$> (PutFile <$> genFilePath <*> arbitrary))
    , (5, Untyped . GetFile    <$> elements (Map.keys m))
    , (1, Untyped . DeleteFile <$> elements (Map.keys m))
    ]

shrinker :: Action v resp -> [Action v resp]
shrinker (PutFile file contents) =
  [ PutFile file contents' | contents' <- shrink contents ]
shrinker _                       = []

------------------------------------------------------------------------

semantics :: Action Concrete resp -> ReaderT ClientEnv IO resp
semantics act = do
  env <- ask
  res <- liftIO $ flip runClientM env $ case act of
    PutFile    file content -> putFileC    file content
    GetFile    file         -> getFileC    file
    DeleteFile file         -> deleteFileC file
  case res of
    Left  err  -> error (show err)
    Right resp -> return resp

------------------------------------------------------------------------

instance HTraversable Action where
  htraverse _ (PutFile    file content) = pure (PutFile    file content)
  htraverse _ (GetFile    file)         = pure (GetFile    file)
  htraverse _ (DeleteFile file)         = pure (DeleteFile file)

instance HFunctor  Action
instance HFoldable Action

instance Show (Untyped Action) where
  show (Untyped act) = show act

instance Constructors Action where
  constructor x = Constructor $ case x of
    PutFile{}    -> "PutFile"
    GetFile{}    -> "GetFile"
    DeleteFile{} -> "DeleteFile"
  nConstructors _ = 3

------------------------------------------------------------------------

burl :: BaseUrl
burl = BaseUrl Http "localhost" 8080 ""

setup :: MonadBaseControl IO m => m (Async ())
setup = liftBaseWith $ \_ -> do
  pid <- async runServer
  res <- poll pid
  case res of
    Nothing         -> return ()
    Just (Left err) -> error (show err)
    Just (Right _)  -> error "setup: impossible, server shouldn't return."
  return pid

runner :: ReaderT ClientEnv IO Property -> IO Property
runner p = do
  mgr <- newManager defaultManagerSettings
  runReaderT p (ClientEnv mgr burl)

------------------------------------------------------------------------

sm :: StateMachine Model Action (ReaderT ClientEnv IO)
sm = StateMachine
  generator shrinker preconditions transitions
  postconditions initModel semantics runner

prop_crudWebserverFile :: Property
prop_crudWebserverFile =
  bracketP setup cancel $ \_ ->
    monadicSequential sm $ \prog -> do
      (hist, model, prop) <- runProgram sm prog
      prettyProgram prog hist model $
        checkActionNames prog prop

prop_crudWebserverFileParallel :: Property
prop_crudWebserverFileParallel =
  bracketP setup cancel $ \_ ->
    monadicParallel sm $ \prog ->
      prettyParallelProgram prog =<< runParallelProgram sm prog