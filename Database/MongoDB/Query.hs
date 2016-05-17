-- | Query and update documents

{-# LANGUAGE OverloadedStrings, RecordWildCards, NamedFieldPuns, TupleSections, FlexibleContexts, FlexibleInstances, UndecidableInstances, MultiParamTypeClasses, GeneralizedNewtypeDeriving, StandaloneDeriving, TypeSynonymInstances, TypeFamilies, CPP, DeriveDataTypeable #-}

module Database.MongoDB.Query (
    -- * Monad
    Action, access, Failure(..), ErrorCode,
    AccessMode(..), GetLastError, master, slaveOk, accessMode,
    liftDB,
    MongoContext(..), HasMongoContext(..),
    -- * Database
    Database, allDatabases, useDb, thisDatabase,
    -- ** Authentication
    Username, Password, auth, authMongoCR, authSCRAMSHA1,
    -- * Collection
    Collection, allCollections,
    -- ** Selection
    Selection(..), Selector, whereJS,
    Select(select),
    -- * Write
    -- ** Insert
    insert, insert_, insertMany, insertMany_, insertAll, insertAll_,
    -- ** Update
    save, replace, repsert, upsert, Modifier, modify,
    -- ** Delete
    delete, deleteOne,
    -- * Read
    -- ** Query
    Query(..), QueryOption(NoCursorTimeout, TailableCursor, AwaitData, Partial),
    Projector, Limit, Order, BatchSize,
    explain, find, findOne, fetch,
    findAndModify, findAndModifyOpts, FindAndModifyOpts(..), defFamUpdateOpts,
    count, distinct,
    -- *** Cursor
    Cursor, nextBatch, next, nextN, rest, closeCursor, isCursorClosed,
    -- ** Aggregate
    Pipeline, aggregate,
    -- ** Group
    Group(..), GroupKey(..), group,
    -- ** MapReduce
    MapReduce(..), MapFun, ReduceFun, FinalizeFun, MROut(..), MRMerge(..),
    MRResult, mapReduce, runMR, runMR',
    -- * Command
    Command, runCommand, runCommand1,
    eval,
) where

import Prelude hiding (lookup)
import Control.Exception (Exception, throwIO)
import Control.Monad (unless, replicateM, liftM)
import Data.Int (Int32)
import Data.Maybe (listToMaybe, catMaybes, isNothing)
import Data.Word (Word32)
#if !MIN_VERSION_base(4,8,0)
import Data.Monoid (mappend)
#endif
import Data.Typeable (Typeable)

#if MIN_VERSION_base(4,6,0)
import Control.Concurrent.MVar.Lifted (MVar, newMVar, mkWeakMVar,
                                       readMVar, modifyMVar)
#else
import Control.Concurrent.MVar.Lifted (MVar, newMVar, addMVarFinalizer,
                                         readMVar, modifyMVar)
#endif
import Control.Applicative ((<$>))
import Control.Monad (when)
import Control.Monad.Base (MonadBase)
import Control.Monad.Error (Error(..))
import Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask, asks, local)
import Control.Monad.Trans (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl(..))
import Data.Bson (Document, Field(..), Label, Val, Value(String, Doc, Bool),
                  Javascript, at, valueAt, lookup, look, genObjectId, (=:),
                  (=?))

import Database.MongoDB.Internal.Protocol (Reply(..), QueryOption(..),
                                           ResponseFlag(..), InsertOption(..),
                                           UpdateOption(..), DeleteOption(..),
                                           CursorId, FullCollection, Username,
                                           Password, Pipe, Notice(..),
                                           Request(GetMore, qOptions, qSkip,
                                           qFullCollection, qBatchSize,
                                           qSelector, qProjector),
                                           pwKey)
import Database.MongoDB.Internal.Util (loop, liftIOE, true1, (<.>))
import qualified Database.MongoDB.Internal.Protocol as P

import qualified Crypto.Nonce as Nonce
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B
import qualified Crypto.Hash.MD5 as MD5
import qualified Crypto.Hash.SHA1 as SHA1
import qualified Crypto.MAC.HMAC as HMAC
import Data.Bits (xor)
import qualified Data.Map as Map
import Text.Read (readMaybe)

#if !MIN_VERSION_base(4,6,0)
--mkWeakMVar = addMVarFinalizer
#endif

-- * Monad

type Action = ReaderT MongoContext
-- ^ A monad on top of m (which must be a MonadIO) that may access the database and may fail with a DB 'Failure'

access :: (MonadIO m) => Pipe -> AccessMode -> Database -> Action m a -> m a
-- ^ Run action against database on server at other end of pipe. Use access mode for any reads and writes. Return Left on connection failure or read/write failure.
access mongoPipe mongoAccessMode mongoDatabase action = runReaderT action MongoContext{..}

-- | A connection failure, or a read or write exception like cursor expired or inserting a duplicate key.
-- Note, unexpected data from the server is not a Failure, rather it is a programming error (you should call 'error' in this case) because the client and server are incompatible and requires a programming change.
data Failure =
     ConnectionFailure IOError  -- ^ TCP connection ('Pipeline') failed. May work if you try again on the same Mongo 'Connection' which will create a new Pipe.
    | CursorNotFoundFailure CursorId  -- ^ Cursor expired because it wasn't accessed for over 10 minutes, or this cursor came from a different server that the one you are currently connected to (perhaps a fail over happen between servers in a replica set)
    | QueryFailure ErrorCode String  -- ^ Query failed for some reason as described in the string
    | WriteFailure ErrorCode String  -- ^ Error observed by getLastError after a write, error description is in string
    | DocNotFound Selection  -- ^ 'fetch' found no document matching selection
    | AggregateFailure String -- ^ 'aggregate' returned an error
    deriving (Show, Eq, Typeable)
instance Exception Failure

type ErrorCode = Int
-- ^ Error code from getLastError or query failure

instance Error Failure where strMsg = error
-- ^ 'fail' is treated the same as a programming 'error'. In other words, don't use it.

-- | Type of reads and writes to perform
data AccessMode =
     ReadStaleOk  -- ^ Read-only action, reading stale data from a slave is OK.
    | UnconfirmedWrites  -- ^ Read-write action, slave not OK, every write is fire & forget.
    | ConfirmWrites GetLastError  -- ^ Read-write action, slave not OK, every write is confirmed with getLastError.
    deriving Show

type GetLastError = Document
-- ^ Parameters for getLastError command. For example @[\"w\" =: 2]@ tells the server to wait for the write to reach at least two servers in replica set before acknowledging. See <http://www.mongodb.org/display/DOCS/Last+Error+Commands> for more options.

master :: AccessMode
-- ^ Same as 'ConfirmWrites' []
master = ConfirmWrites []

slaveOk :: AccessMode
-- ^ Same as 'ReadStaleOk'
slaveOk = ReadStaleOk

accessMode :: (Monad m) => AccessMode -> Action m a -> Action m a
-- ^ Run action with given 'AccessMode'
accessMode mode act = local (\ctx -> ctx {mongoAccessMode = mode}) act

readMode :: AccessMode -> ReadMode
readMode ReadStaleOk = StaleOk
readMode _ = Fresh

writeMode :: AccessMode -> WriteMode
writeMode ReadStaleOk = Confirm []
writeMode UnconfirmedWrites = NoConfirm
writeMode (ConfirmWrites z) = Confirm z

-- | Values needed when executing a db operation
data MongoContext = MongoContext {
    mongoPipe :: Pipe, -- ^ operations read/write to this pipelined TCP connection to a MongoDB server
    mongoAccessMode :: AccessMode, -- ^ read/write operation will use this access mode
    mongoDatabase :: Database } -- ^ operations query/update this database

mongoReadMode :: MongoContext -> ReadMode
mongoReadMode = readMode . mongoAccessMode

mongoWriteMode :: MongoContext -> WriteMode
mongoWriteMode = writeMode . mongoAccessMode

send :: (MonadIO m) => [Notice] -> Action m ()
-- ^ Send notices as a contiguous batch to server with no reply. Throw 'ConnectionFailure' if pipe fails.
send ns = do
    pipe <- asks mongoPipe
    liftIOE ConnectionFailure $ P.send pipe ns

call :: (MonadIO m) => [Notice] -> Request -> Action m (IO Reply)
-- ^ Send notices and request as a contiguous batch to server and return reply promise, which will block when invoked until reply arrives. This call will throw 'ConnectionFailure' if pipe fails on send, and promise will throw 'ConnectionFailure' if pipe fails on receive.
call ns r = do
    pipe <- asks mongoPipe
    promise <- liftIOE ConnectionFailure $ P.call pipe ns r
    return (liftIOE ConnectionFailure promise)

class HasMongoContext env where
    mongoContext :: env -> MongoContext
instance HasMongoContext MongoContext where
    mongoContext = id

liftDB :: (MonadReader env m, HasMongoContext env, MonadIO m)
       => Action IO a
       -> m a
liftDB m = do
    env <- ask
    liftIO $ runReaderT m (mongoContext env)

-- * Database

type Database = BS.ByteString

allDatabases :: (MonadIO m) => Action m [Database]
-- ^ List all databases residing on server
allDatabases = (map (at "name") . at "databases") `liftM` useDb "admin" (runCommand1 "listDatabases")

thisDatabase :: (Monad m) => Action m Database
-- ^ Current database in use
thisDatabase = asks mongoDatabase

useDb :: (Monad m) => Database -> Action m a -> Action m a
-- ^ Run action against given database
useDb db act = local (\ctx -> ctx {mongoDatabase = db}) act

-- * Authentication

auth :: MonadIO m => Username -> Password -> Action m Bool
-- ^ Authenticate with the current database (if server is running in secure mode). Return whether authentication was successful or not. Reauthentication is required for every new pipe. SCRAM-SHA-1 will be used for server versions 3.0+, MONGO-CR for lower versions.
auth un pw = do
    let serverVersion = liftM (at "version") $ useDb "admin" $ runCommand ["buildinfo" =: (1 :: Int)]
    mmv <- liftM (readMaybe . B.unpack . head . B.split '.') $ serverVersion
    maybe (return False) performAuth mmv
    where
    performAuth majorVersion =
        case (majorVersion >= (3 :: Int)) of
            True -> authSCRAMSHA1 un pw
            False -> authMongoCR un pw

authMongoCR :: (MonadIO m) => Username -> Password -> Action m Bool
-- ^ Authenticate with the current database, using the MongoDB-CR authentication mechanism (default in MongoDB server < 3.0)
authMongoCR usr pss = do
    n <- at "nonce" `liftM` runCommand ["getnonce" =: (1 :: Int)]
    true1 "ok" `liftM` runCommand ["authenticate" =: (1 :: Int), "user" =: usr, "nonce" =: n, "key" =: pwKey n usr pss]

authSCRAMSHA1 :: MonadIO m => Username -> Password -> Action m Bool
-- ^ Authenticate with the current database, using the SCRAM-SHA-1 authentication mechanism (default in MongoDB server >= 3.0)
authSCRAMSHA1 un pw = do
    let hmac = HMAC.hmac SHA1.hash 64
    nonce <- (Nonce.new >>= Nonce.nonce128 >>= return . B64.encode)
    let firstBare = B.concat [B.pack $ "n=" ++ (B.unpack un) ++ ",r=", nonce]
    let client1 = ["saslStart" =: (1 :: Int), "mechanism" =: ("SCRAM-SHA-1" :: String), "payload" =: (B.unpack . B64.encode $ B.concat [B.pack "n,,", firstBare]), "autoAuthorize" =: (1 :: Int)]
    server1 <- runCommand client1

    shortcircuit (true1 "ok" server1) $ do
        let serverPayload1 = B64.decodeLenient . B.pack . at "payload" $ server1
        let serverData1 = parseSCRAM serverPayload1
        let iterations = read . B.unpack $ Map.findWithDefault "1" "i" serverData1
        let salt = B64.decodeLenient $ Map.findWithDefault "" "s" serverData1
        let snonce = Map.findWithDefault "" "r" serverData1

        shortcircuit (B.isInfixOf nonce snonce) $ do
            let withoutProof = B.concat [B.pack "c=biws,r=", snonce]
            let digestS = B.pack $ B.unpack un ++ ":mongo:" ++ B.unpack pw
            let digest = B16.encode $ MD5.hash digestS
            let saltedPass = scramHI digest salt iterations
            let clientKey = hmac saltedPass (B.pack "Client Key")
            let storedKey = SHA1.hash clientKey
            let authMsg = B.concat [firstBare, B.pack ",", serverPayload1, B.pack ",", withoutProof]
            let clientSig = hmac storedKey authMsg
            let pval = B64.encode . BS.pack $ BS.zipWith xor clientKey clientSig
            let clientFinal = B.concat [withoutProof, B.pack ",p=", pval]
            let serverKey = hmac saltedPass (B.pack "Server Key")
            let serverSig = B64.encode $ hmac serverKey authMsg
            let client2 = ["saslContinue" =: (1 :: Int), "conversationId" =: (at "conversationId" server1 :: Int), "payload" =: (B.unpack $ B64.encode clientFinal)]
            server2 <- runCommand client2

            shortcircuit (true1 "ok" server2) $ do
                let serverPayload2 = B64.decodeLenient . B.pack $ at "payload" server2
                let serverData2 = parseSCRAM serverPayload2
                let serverSigComp = Map.findWithDefault "" "v" serverData2

                shortcircuit (serverSig == serverSigComp) $ do
                  let done = true1 "done" server2
                  if done
                    then return True
                    else do
                      let client2 = ["saslContinue" =: (1 :: Int), "conversationId" =: (at "conversationId" server1 :: Int), "payload" =: String ""]
                      server3 <- runCommand client2
                      shortcircuit (true1 "ok" server3) $ do
                        return True
    where
    shortcircuit True f = f
    shortcircuit False _ = return False

scramHI :: B.ByteString -> B.ByteString -> Int -> B.ByteString
scramHI digest salt iters = snd $ foldl com (u1, u1) [1..(iters-1)]
    where
    hmacd = HMAC.hmac SHA1.hash 64 digest
    u1 = hmacd (B.concat [salt, BS.pack [0, 0, 0, 1]])
    com (u,uc) _ = let u' = hmacd u in (u', BS.pack $ BS.zipWith xor uc u')

parseSCRAM :: B.ByteString -> Map.Map B.ByteString B.ByteString
parseSCRAM = Map.fromList . fmap cleanup . (fmap $ B.break (== '=')) . B.split ','
    where cleanup (t1, t2) = (t1, B.drop 1 t2)

-- * Collection

type Collection = BS.ByteString
-- ^ Collection name (not prefixed with database)

allCollections :: (MonadIO m, MonadBaseControl IO m) => Action m [Collection]
-- ^ List all collections in this database
allCollections = do
    db <- thisDatabase
    docs <- rest =<< find (query [] "system.namespaces") {sort = ["name" =: (1 :: Int)]}
    return . filter (not . isSpecial db) . map dropDbPrefix $ map (at "name") docs
 where
    dropDbPrefix = B.tail . B.dropWhile (/= '.')
    isSpecial db col = B.any (== '$') col && db <.> col /= "local.oplog.$main"

-- * Selection

data Selection = Select {selector :: Selector, coll :: Collection}  deriving (Show, Eq)
-- ^ Selects documents in collection that match selector

type Selector = Document
-- ^ Filter for a query, analogous to the where clause in SQL. @[]@ matches all documents in collection. @[\"x\" =: a, \"y\" =: b]@ is analogous to @where x = a and y = b@ in SQL. See <http://www.mongodb.org/display/DOCS/Querying> for full selector syntax.

whereJS :: Selector -> Javascript -> Selector
-- ^ Add Javascript predicate to selector, in which case a document must match both selector and predicate
whereJS sel js = ("$where" =: js) : sel

class Select aQueryOrSelection where
    select :: Selector -> Collection -> aQueryOrSelection
    -- ^ 'Query' or 'Selection' that selects documents in collection that match selector. The choice of type depends on use, for example, in @'find' (select sel col)@ it is a Query, and in @'delete' (select sel col)@ it is a Selection.

instance Select Selection where
    select = Select

instance Select Query where
    select = query

-- * Write

data WriteMode =
      NoConfirm  -- ^ Submit writes without receiving acknowledgments. Fast. Assumes writes succeed even though they may not.
    | Confirm GetLastError  -- ^ Receive an acknowledgment after every write, and raise exception if one says the write failed. This is acomplished by sending the getLastError command, with given 'GetLastError' parameters, after every write.
    deriving (Show, Eq)

write :: (MonadIO m) => Notice -> Action m ()
-- ^ Send write to server, and if write-mode is 'Safe' then include getLastError request and raise 'WriteFailure' if it reports an error.
write notice = asks mongoWriteMode >>= \mode -> case mode of
    NoConfirm -> send [notice]
    Confirm params -> do
        let q = query (("getlasterror" =: (1 :: Int)) : params) "$cmd"
        Batch _ _ [doc] <- fulfill =<< request [notice] =<< queryRequest False q {limit = 1}
        case lookup "err" doc of
            Nothing -> return ()
            Just err -> liftIO $ throwIO $ WriteFailure (maybe 0 id $ lookup "code" doc) err

-- ** Insert

insert :: (MonadIO m) => Collection -> Document -> Action m Value
-- ^ Insert document into collection and return its \"_id\" value, which is created automatically if not supplied
insert col doc = head `liftM` insertMany col [doc]

insert_ :: (MonadIO m) => Collection -> Document -> Action m ()
-- ^ Same as 'insert' except don't return _id
insert_ col doc = insert col doc >> return ()

insertMany :: (MonadIO m) => Collection -> [Document] -> Action m [Value]
-- ^ Insert documents into collection and return their \"_id\" values, which are created automatically if not supplied. If a document fails to be inserted (eg. due to duplicate key) then remaining docs are aborted, and LastError is set.
insertMany = insert' []

insertMany_ :: (MonadIO m) => Collection -> [Document] -> Action m ()
-- ^ Same as 'insertMany' except don't return _ids
insertMany_ col docs = insertMany col docs >> return ()

insertAll :: (MonadIO m) => Collection -> [Document] -> Action m [Value]
-- ^ Insert documents into collection and return their \"_id\" values, which are created automatically if not supplied. If a document fails to be inserted (eg. due to duplicate key) then remaining docs are still inserted. LastError is set if any doc fails, not just last one.
insertAll = insert' [KeepGoing]

insertAll_ :: (MonadIO m) => Collection -> [Document] -> Action m ()
-- ^ Same as 'insertAll' except don't return _ids
insertAll_ col docs = insertAll col docs >> return ()

insert' :: (MonadIO m) => [InsertOption] -> Collection -> [Document] -> Action m [Value]
-- ^ Insert documents into collection and return their \"_id\" values, which are created automatically if not supplied
insert' opts col docs = do
    db <- thisDatabase
    docs' <- liftIO $ mapM assignId docs
    write (Insert (db <.> col) opts docs')
    return $ map (valueAt "_id") docs'

assignId :: Document -> IO Document
-- ^ Assign a unique value to _id field if missing
assignId doc = if any (("_id" ==) . label) doc
    then return doc
    else (\oid -> ("_id" =: oid) : doc) `liftM` genObjectId

-- ** Update

save :: (MonadIO m) => Collection -> Document -> Action m ()
-- ^ Save document to collection, meaning insert it if its new (has no \"_id\" field) or upsert it if its not new (has \"_id\" field)
save col doc = case look "_id" doc of
    Nothing -> insert_ col doc
    Just i -> upsert (Select ["_id" := i] col) doc

replace :: (MonadIO m) => Selection -> Document -> Action m ()
-- ^ Replace first document in selection with given document
replace = update []

repsert :: (MonadIO m) => Selection -> Document -> Action m ()
-- ^ Replace first document in selection with given document, or insert document if selection is empty
repsert = update [Upsert]
{-# DEPRECATED repsert "use upsert instead" #-}

upsert :: (MonadIO m) => Selection -> Document -> Action m ()
-- ^ Update first document in selection with given document, or insert document if selection is empty
upsert = update [Upsert]

type Modifier = Document
-- ^ Update operations on fields in a document. See <http://www.mongodb.org/display/DOCS/Updating#Updating-ModifierOperations>

modify :: (MonadIO m) => Selection -> Modifier -> Action m ()
-- ^ Update all documents in selection using given modifier
modify = update [MultiUpdate]

update :: (MonadIO m) => [UpdateOption] -> Selection -> Document -> Action m ()
-- ^ Update first document in selection using updater document, unless 'MultiUpdate' option is supplied then update all documents in selection. If 'Upsert' option is supplied then treat updater as document and insert it if selection is empty.
update opts (Select sel col) up = do
    db <- thisDatabase
    write (Update (db <.> col) opts sel up)

-- ** Delete

delete :: (MonadIO m) => Selection -> Action m ()
-- ^ Delete all documents in selection
delete = delete' []

deleteOne :: (MonadIO m) => Selection -> Action m ()
-- ^ Delete first document in selection
deleteOne = delete' [SingleRemove]

delete' :: (MonadIO m) => [DeleteOption] -> Selection -> Action m ()
-- ^ Delete all documents in selection unless 'SingleRemove' option is given then only delete first document in selection
delete' opts (Select sel col) = do
    db <- thisDatabase
    write (Delete (db <.> col) opts sel)

-- * Read

data ReadMode =
      Fresh  -- ^ read from master only
    | StaleOk  -- ^ read from slave ok
    deriving (Show, Eq)

readModeOption :: ReadMode -> [QueryOption]
readModeOption Fresh = []
readModeOption StaleOk = [SlaveOK]

-- ** Query

-- | Use 'select' to create a basic query with defaults, then modify if desired. For example, @(select sel col) {limit = 10}@
data Query = Query {
    options :: [QueryOption],  -- ^ Default = []
    selection :: Selection,
    project :: Projector,  -- ^ \[\] = all fields. Default = []
    skip :: Word32,  -- ^ Number of initial matching documents to skip. Default = 0
    limit :: Limit, -- ^ Maximum number of documents to return, 0 = no limit. Default = 0
    sort :: Order,  -- ^ Sort results by this order, [] = no sort. Default = []
    snapshot :: Bool,  -- ^ If true assures no duplicates are returned, or objects missed, which were present at both the start and end of the query's execution (even if the object were updated). If an object is new during the query, or deleted during the query, it may or may not be returned, even with snapshot mode. Note that short query responses (less than 1MB) are always effectively snapshotted. Default = False
    batchSize :: BatchSize,  -- ^ The number of document to return in each batch response from the server. 0 means use Mongo default. Default = 0
    hint :: Order  -- ^ Force MongoDB to use this index, [] = no hint. Default = []
    } deriving (Show, Eq)

type Projector = Document
-- ^ Fields to return, analogous to the select clause in SQL. @[]@ means return whole document (analogous to * in SQL). @[\"x\" =: 1, \"y\" =: 1]@ means return only @x@ and @y@ fields of each document. @[\"x\" =: 0]@ means return all fields except @x@.

type Limit = Word32
-- ^ Maximum number of documents to return, i.e. cursor will close after iterating over this number of documents. 0 means no limit.

type Order = Document
-- ^ Fields to sort by. Each one is associated with 1 or -1. Eg. @[\"x\" =: 1, \"y\" =: -1]@ means sort by @x@ ascending then @y@ descending

type BatchSize = Word32
-- ^ The number of document to return in each batch response from the server. 0 means use Mongo default.

query :: Selector -> Collection -> Query
-- ^ Selects documents in collection that match selector. It uses no query options, projects all fields, does not skip any documents, does not limit result size, uses default batch size, does not sort, does not hint, and does not snapshot.
query sel col = Query [] (Select sel col) [] 0 0 [] False 0 []

find :: (MonadIO m, MonadBaseControl IO m) => Query -> Action m Cursor
-- ^ Fetch documents satisfying query
find q@Query{selection, batchSize} = do
    db <- thisDatabase
    dBatch <- request [] =<< queryRequest False q
    newCursor db (coll selection) batchSize dBatch

findOne :: (MonadIO m) => Query -> Action m (Maybe Document)
-- ^ Fetch first document satisfying query or Nothing if none satisfy it
findOne q = do
    Batch _ _ docs <- fulfill =<< request [] =<< queryRequest False q {limit = 1}
    return (listToMaybe docs)

fetch :: (MonadIO m) => Query -> Action m Document
-- ^ Same as 'findOne' except throw 'DocNotFound' if none match
fetch q = findOne q >>= maybe (liftIO $ throwIO $ DocNotFound $ selection q) return

data FindAndModifyOpts = FamRemove Bool
                       | FamUpdate
                         { famUpdate :: Document
                         , famNew :: Bool
                         , famUpsert :: Bool
                         }
                       deriving Show

defFamUpdateOpts :: Document -> FindAndModifyOpts
defFamUpdateOpts ups = FamUpdate
                       { famNew = True
                       , famUpsert = False
                       , famUpdate = ups
                       }

-- | runs the findAndModify command as an update without an upsert and new set to true.
-- Returns a single updated document (new option is set to true).
--
-- see 'findAndModifyOpts' if you want to use findAndModify in a differnt way
findAndModify :: MonadIO m
              => Query
              -> Document -- ^ updates
              -> Action m (Either String Document)
findAndModify q ups = do
  eres <- findAndModifyOpts q (defFamUpdateOpts ups)
  return $ case eres of
    Left l -> Left l
    Right r -> case r of
      -- only possible when upsert is True and new is False
      Nothing  -> Left "findAndModify: impossible null result"
      Just doc -> Right doc

-- | runs the findAndModify command,
-- allows more options than 'findAndModify'
findAndModifyOpts :: MonadIO m
                  => Query
                  ->FindAndModifyOpts
                  -> Action m (Either String (Maybe Document))
findAndModifyOpts (Query {
    selection = Select sel collection
  , project = project
  , sort = sort
  }) famOpts = do
    result <- runCommand
       ([ "findAndModify" := String collection
        , "query"  := Doc sel
        , "fields" := Doc project
        , "sort"   := Doc sort
        ] ++
            case famOpts of
              FamRemove shouldRemove -> [ "remove" := Bool shouldRemove ]
              FamUpdate {..} ->
                [ "update" := Doc famUpdate
                , "new"    := Bool famNew    -- return updated document, not original document
                , "upsert" := Bool famUpsert -- insert if nothing is found
                ])
    return $ case lookupErr result of
        Just e -> leftErr e
        Nothing -> case lookup "value" result of
            Left err   -> leftErr $ "no document found: " `mappend` err
            Right mdoc -> case mdoc of
                Just doc@(_:_) -> Right (Just doc)
                Just [] -> case famOpts of
                    FamUpdate { famUpsert = True, famNew = False } -> Right Nothing
                    _ -> leftErr $ show result
                _  -> leftErr $ show result
  where
    leftErr err = Left $ "findAndModify " `mappend` show collection
        `mappend` "\nfrom query: " `mappend` show sel
        `mappend` "\nerror: " `mappend` err

    -- return Nothing means ok, Just is the error message
    lookupErr result = case lookup "lastErrorObject" result of
        Right errObject -> lookup "err" errObject
        Left err -> Just err

explain :: (MonadIO m) => Query -> Action m Document
-- ^ Return performance stats of query execution
explain q = do  -- same as findOne but with explain set to true
    Batch _ _ docs <- fulfill =<< request [] =<< queryRequest True q {limit = 1}
    return $ if null docs then error ("no explain: " ++ show q) else head docs

count :: (MonadIO m) => Query -> Action m Int
-- ^ Fetch number of documents satisfying query (including effect of skip and/or limit if present)
count Query{selection = Select sel col, skip, limit} = at "n" `liftM` runCommand
    (["count" =: col, "query" =: sel, "skip" =: (fromIntegral skip :: Int32)]
        ++ ("limit" =? if limit == 0 then Nothing else Just (fromIntegral limit :: Int32)))

distinct :: (MonadIO m) => Label -> Selection -> Action m [Value]
-- ^ Fetch distinct values of field in selected documents
distinct k (Select sel col) = at "values" `liftM` runCommand ["distinct" =: col, "key" =: k, "query" =: sel]

queryRequest :: (Monad m) => Bool -> Query -> Action m (Request, Maybe Limit)
-- ^ Translate Query to Protocol.Query. If first arg is true then add special $explain attribute.
queryRequest isExplain Query{..} = do
    ctx <- ask
    return $ queryRequest' (mongoReadMode ctx) (mongoDatabase ctx)
 where
    queryRequest' rm db = (P.Query{..}, remainingLimit) where
        qOptions = readModeOption rm ++ options
        qFullCollection = db <.> coll selection
        qSkip = fromIntegral skip
        (qBatchSize, remainingLimit) = batchSizeRemainingLimit batchSize (if limit == 0 then Nothing else Just limit)
        qProjector = project
        mOrder = if null sort then Nothing else Just ("$orderby" =: sort)
        mSnapshot = if snapshot then Just ("$snapshot" =: True) else Nothing
        mHint = if null hint then Nothing else Just ("$hint" =: hint)
        mExplain = if isExplain then Just ("$explain" =: True) else Nothing
        special = catMaybes [mOrder, mSnapshot, mHint, mExplain]
        qSelector = if null special then s else ("$query" =: s) : special where s = selector selection

batchSizeRemainingLimit :: BatchSize -> (Maybe Limit) -> (Int32, Maybe Limit)
-- ^ Given batchSize and limit return P.qBatchSize and remaining limit
batchSizeRemainingLimit batchSize mLimit =
  let remaining =
        case mLimit of
          Nothing    -> batchSize
          Just limit ->
            if 0 < batchSize && batchSize < limit
              then batchSize
              else limit
  in (fromIntegral remaining, mLimit)

type DelayedBatch = IO Batch
-- ^ A promised batch which may fail

data Batch = Batch (Maybe Limit) CursorId [Document]
-- ^ CursorId = 0 means cursor is finished. Documents is remaining documents to serve in current batch. Limit is number of documents to return. Nothing means no limit.

request :: (MonadIO m) => [Notice] -> (Request, Maybe Limit) -> Action m DelayedBatch
-- ^ Send notices and request and return promised batch
request ns (req, remainingLimit) = do
    promise <- call ns req
    return $ fromReply remainingLimit =<< promise

fromReply :: Maybe Limit -> Reply -> DelayedBatch
-- ^ Convert Reply to Batch or Failure
fromReply limit Reply{..} = do
    mapM_ checkResponseFlag rResponseFlags
    return (Batch limit rCursorId rDocuments)
 where
    -- If response flag indicates failure then throw it, otherwise do nothing
    checkResponseFlag flag = case flag of
        AwaitCapable -> return ()
        CursorNotFound -> throwIO $ CursorNotFoundFailure rCursorId
        QueryError -> throwIO $ QueryFailure (at "code" $ head rDocuments) (at "$err" $ head rDocuments)

fulfill :: (MonadIO m) => DelayedBatch -> Action m Batch
-- ^ Demand and wait for result, raise failure if exception
fulfill = liftIO

-- *** Cursor

data Cursor = Cursor FullCollection BatchSize (MVar DelayedBatch)
-- ^ Iterator over results of a query. Use 'next' to iterate or 'rest' to get all results. A cursor is closed when it is explicitly closed, all results have been read from it, garbage collected, or not used for over 10 minutes (unless 'NoCursorTimeout' option was specified in 'Query'). Reading from a closed cursor raises a 'CursorNotFoundFailure'. Note, a cursor is not closed when the pipe is closed, so you can open another pipe to the same server and continue using the cursor.

newCursor :: (MonadIO m, MonadBaseControl IO m) => Database -> Collection -> BatchSize -> DelayedBatch -> Action m Cursor
-- ^ Create new cursor. If you don't read all results then close it. Cursor will be closed automatically when all results are read from it or when eventually garbage collected.
newCursor db col batchSize dBatch = do
    var <- newMVar dBatch
    let cursor = Cursor (db <.> col) batchSize var
    _ <- mkWeakMVar var (closeCursor cursor)
    return cursor
#if !MIN_VERSION_base(4,6,0)
  where mkWeakMVar = addMVarFinalizer
#endif

nextBatch :: (MonadIO m, MonadBaseControl IO m) => Cursor -> Action m [Document]
-- ^ Return next batch of documents in query result, which will be empty if finished.
nextBatch (Cursor fcol batchSize var) = modifyMVar var $ \dBatch -> do
    -- Pre-fetch next batch promise from server and return current batch.
    Batch mLimit cid docs <- fulfill' fcol batchSize dBatch
    let newLimit = do
              limit <- mLimit
              return $ limit - (min limit $ fromIntegral $ length docs)
    let emptyBatch = return $ Batch (Just 0) 0 []
    let getNextBatch = nextBatch' fcol batchSize newLimit cid
    let resultDocs = (maybe id (take . fromIntegral) mLimit) docs
    case (cid, newLimit) of
      (0, _)      -> return (emptyBatch, resultDocs)
      (_, Just 0) -> do
        send [KillCursors [cid]]
        return (emptyBatch, resultDocs)
      (_, _)      -> (, resultDocs) <$> getNextBatch

fulfill' :: (MonadIO m) => FullCollection -> BatchSize -> DelayedBatch -> Action m Batch
-- Discard pre-fetched batch if empty with nonzero cid.
fulfill' fcol batchSize dBatch = do
    b@(Batch limit cid docs) <- fulfill dBatch
    if cid /= 0 && null docs && (limit > (Just 0))
        then nextBatch' fcol batchSize limit cid >>= fulfill
        else return b

nextBatch' :: (MonadIO m) => FullCollection -> BatchSize -> (Maybe Limit) -> CursorId -> Action m DelayedBatch
nextBatch' fcol batchSize limit cid = do
    request [] (GetMore fcol batchSize' cid, remLimit)
    where (batchSize', remLimit) = batchSizeRemainingLimit batchSize limit

next :: (MonadIO m, MonadBaseControl IO m) => Cursor -> Action m (Maybe Document)
-- ^ Return next document in query result, or Nothing if finished.
next (Cursor fcol batchSize var) = modifyMVar var nextState where
    -- Pre-fetch next batch promise from server when last one in current batch is returned.
    -- nextState:: DelayedBatch -> Action m (DelayedBatch, Maybe Document)
    nextState dBatch = do
        Batch mLimit cid docs <- fulfill' fcol batchSize dBatch
        if mLimit == (Just 0)
          then return (return $ Batch (Just 0) 0 [], Nothing)
          else
            case docs of
                doc : docs' -> do
                    let newLimit = do
                              limit <- mLimit
                              return $ limit - 1
                    dBatch' <- if null docs' && cid /= 0 && ((newLimit > (Just 0)) || (isNothing newLimit))
                        then nextBatch' fcol batchSize newLimit cid
                        else return $ return (Batch newLimit cid docs')
                    when (newLimit == (Just 0)) $ unless (cid == 0) $ send [KillCursors [cid]]
                    return (dBatch', Just doc)
                [] -> if cid == 0
                    then return (return $ Batch (Just 0) 0 [], Nothing)  -- finished
                    else fmap (,Nothing) $ nextBatch' fcol batchSize mLimit cid

nextN :: (MonadIO m, MonadBaseControl IO m) => Int -> Cursor -> Action m [Document]
-- ^ Return next N documents or less if end is reached
nextN n c = catMaybes `liftM` replicateM n (next c)

rest :: (MonadIO m, MonadBaseControl IO m) => Cursor -> Action m [Document]
-- ^ Return remaining documents in query result
rest c = loop (next c)

closeCursor :: (MonadIO m, MonadBaseControl IO m) => Cursor -> Action m ()
closeCursor (Cursor _ _ var) = modifyMVar var $ \dBatch -> do
    Batch _ cid _ <- fulfill dBatch
    unless (cid == 0) $ send [KillCursors [cid]]
    return $ (return $ Batch (Just 0) 0 [], ())

isCursorClosed :: (MonadIO m, MonadBase IO m) => Cursor -> Action m Bool
isCursorClosed (Cursor _ _ var) = do
        Batch _ cid docs <- fulfill =<< readMVar var
        return (cid == 0 && null docs)

-- ** Aggregate

type Pipeline = [Document]
-- ^ The Aggregate Pipeline

aggregate :: MonadIO m => Collection -> Pipeline -> Action m [Document]
-- ^ Runs an aggregate and unpacks the result. See <http://docs.mongodb.org/manual/core/aggregation/> for details.
aggregate aColl agg = do
    response <- runCommand ["aggregate" =: aColl, "pipeline" =: agg]
    case true1 "ok" response of
        True  -> lookup "result" response
        False -> liftIO $ throwIO $ AggregateFailure $ at "errmsg" response

-- ** Group

-- | Groups documents in collection by key then reduces (aggregates) each group
data Group = Group {
    gColl :: Collection,
    gKey :: GroupKey,  -- ^ Fields to group by
    gReduce :: Javascript,  -- ^ @(doc, agg) -> ()@. The reduce function reduces (aggregates) the objects iterated. Typical operations of a reduce function include summing and counting. It takes two arguments, the current document being iterated over and the aggregation value, and updates the aggregate value.
    gInitial :: Document,  -- ^ @agg@. Initial aggregation value supplied to reduce
    gCond :: Selector,  -- ^ Condition that must be true for a row to be considered. [] means always true.
    gFinalize :: Maybe Javascript  -- ^ @agg -> () | result@. An optional function to be run on each item in the result set just before the item is returned. Can either modify the item (e.g., add an average field given a count and a total) or return a replacement object (returning a new object with just _id and average fields).
    } deriving (Show, Eq)

data GroupKey = Key [Label] | KeyF Javascript  deriving (Show, Eq)
-- ^ Fields to group by, or function (@doc -> key@) returning a "key object" to be used as the grouping key. Use KeyF instead of Key to specify a key that is not an existing member of the object (or, to access embedded members).

groupDocument :: Group -> Document
-- ^ Translate Group data into expected document form
groupDocument Group{..} =
    ("finalize" =? gFinalize) ++ [
    "ns" =: gColl,
    case gKey of Key k -> "key" =: map (=: True) k; KeyF f -> "$keyf" =: f,
    "$reduce" =: gReduce,
    "initial" =: gInitial,
    "cond" =: gCond ]

group :: (MonadIO m) => Group -> Action m [Document]
-- ^ Execute group query and return resulting aggregate value for each distinct key
group g = at "retval" `liftM` runCommand ["group" =: groupDocument g]

-- ** MapReduce

-- | Maps every document in collection to a list of (key, value) pairs, then for each unique key reduces all its associated values to a single result. There are additional parameters that may be set to tweak this basic operation.
-- This implements the latest version of map-reduce that requires MongoDB 1.7.4 or greater. To map-reduce against an older server use runCommand directly as described in http://www.mongodb.org/display/DOCS/MapReduce.
data MapReduce = MapReduce {
    rColl :: Collection,
    rMap :: MapFun,
    rReduce :: ReduceFun,
    rSelect :: Selector,  -- ^ Operate on only those documents selected. Default is [] meaning all documents.
    rSort :: Order,  -- ^ Default is [] meaning no sort
    rLimit :: Limit,  -- ^ Default is 0 meaning no limit
    rOut :: MROut,  -- ^ Output to a collection with a certain merge policy. Default is no collection ('Inline'). Note, you don't want this default if your result set is large.
    rFinalize :: Maybe FinalizeFun,  -- ^ Function to apply to all the results when finished. Default is Nothing.
    rScope :: Document,  -- ^ Variables (environment) that can be accessed from map/reduce/finalize. Default is [].
    rVerbose :: Bool  -- ^ Provide statistics on job execution time. Default is False.
    } deriving (Show, Eq)

type MapFun = Javascript
-- ^ @() -> void@. The map function references the variable @this@ to inspect the current object under consideration. The function must call @emit(key,value)@ at least once, but may be invoked any number of times, as may be appropriate.

type ReduceFun = Javascript
-- ^ @(key, [value]) -> value@. The reduce function receives a key and an array of values and returns an aggregate result value. The MapReduce engine may invoke reduce functions iteratively; thus, these functions must be idempotent.  That is, the following must hold for your reduce function: @reduce(k, [reduce(k,vs)]) == reduce(k,vs)@. If you need to perform an operation only once, use a finalize function. The output of emit (the 2nd param) and reduce should be the same format to make iterative reduce possible.

type FinalizeFun = Javascript
-- ^ @(key, value) -> final_value@. A finalize function may be run after reduction.  Such a function is optional and is not necessary for many map/reduce cases.  The finalize function takes a key and a value, and returns a finalized value.

data MROut =
      Inline -- ^ Return results directly instead of writing them to an output collection. Results must fit within 16MB limit of a single document
    | Output MRMerge Collection (Maybe Database) -- ^ Write results to given collection, in other database if specified. Follow merge policy when entry already exists
    deriving (Show, Eq)

data MRMerge =
      Replace  -- ^ Clear all old data and replace it with new data
    | Merge  -- ^ Leave old data but overwrite entries with the same key with new data
    | Reduce  -- ^ Leave old data but combine entries with the same key via MR's reduce function
    deriving (Show, Eq)

type MRResult = Document
-- ^ Result of running a MapReduce has some stats besides the output. See http://www.mongodb.org/display/DOCS/MapReduce#MapReduce-Resultobject

mrDocument :: MapReduce -> Document
-- ^ Translate MapReduce data into expected document form
mrDocument MapReduce{..} =
    ("mapreduce" =: rColl) :
    ("out" =: mrOutDoc rOut) :
    ("finalize" =? rFinalize) ++ [
    "map" =: rMap,
    "reduce" =: rReduce,
    "query" =: rSelect,
    "sort" =: rSort,
    "limit" =: (fromIntegral rLimit :: Int),
    "scope" =: rScope,
    "verbose" =: rVerbose ]

mrOutDoc :: MROut -> Document
-- ^ Translate MROut into expected document form
mrOutDoc Inline = ["inline" =: (1 :: Int)]
mrOutDoc (Output mrMerge coll mDB) = (mergeName mrMerge =: coll) : mdb mDB where
    mergeName Replace = "replace"
    mergeName Merge = "merge"
    mergeName Reduce = "reduce"
    mdb Nothing = []
    mdb (Just db) = ["db" =: db]

mapReduce :: Collection -> MapFun -> ReduceFun -> MapReduce
-- ^ MapReduce on collection with given map and reduce functions. Remaining attributes are set to their defaults, which are stated in their comments.
mapReduce col map' red = MapReduce col map' red [] [] 0 Inline Nothing [] False

runMR :: (MonadIO m, MonadBaseControl IO m) => MapReduce -> Action m Cursor
-- ^ Run MapReduce and return cursor of results. Error if map/reduce fails (because of bad Javascript)
runMR mr = do
    res <- runMR' mr
    case look "result" res of
        Just (String coll) -> find $ query [] coll
        Just (Doc doc) -> useDb (at "db" doc) $ find $ query [] (at "collection" doc)
        Just x -> error $ "unexpected map-reduce result field: " ++ show x
        Nothing -> newCursor "" "" 0 $ return $ Batch (Just 0) 0 (at "results" res)

runMR' :: (MonadIO m) => MapReduce -> Action m MRResult
-- ^ Run MapReduce and return a MR result document containing stats and the results if Inlined. Error if the map/reduce failed (because of bad Javascript).
runMR' mr = do
    doc <- runCommand (mrDocument mr)
    return $ if true1 "ok" doc then doc else error $ "mapReduce error:\n" ++ show doc ++ "\nin:\n" ++ show mr

-- * Command

type Command = Document
-- ^ A command is a special query or action against the database. See <http://www.mongodb.org/display/DOCS/Commands> for details.

runCommand :: (MonadIO m) => Command -> Action m Document
-- ^ Run command against the database and return its result
runCommand c = maybe err id `liftM` findOne (query c "$cmd") where
    err = error $ "Nothing returned for command: " ++ show c

runCommand1 :: (MonadIO m) => BS.ByteString -> Action m Document
-- ^ @runCommand1 foo = runCommand [foo =: 1]@
runCommand1 c = runCommand [c =: (1 :: Int)]

eval :: (MonadIO m, Val v) => Javascript -> Action m v
-- ^ Run code on server
eval code = at "retval" `liftM` runCommand ["$eval" =: code]


{- Authors: Tony Hannan <tony@10gen.com>
   Copyright 2011 10gen Inc.
   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at: http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License. -}
