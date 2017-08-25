module Config
    ( Environment(..)
    , Config(..)
    , defaultConfig
    ) where

import Database.Persist.Sql (ConnectionPool)

data Environment
    = Production
    | Development
    deriving (Eq, Show, Read)

data Config
    = Config
    { getPool :: ConnectionPool
    , getEnv :: Environment
    , getMediaDirectory :: FilePath
    }

defaultConfig :: Config
defaultConfig =
    Config
        { getPool = undefined
        , getEnv = Development
        , getMediaDirectory = undefined
        }
