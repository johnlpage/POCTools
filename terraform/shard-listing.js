// Shards the "listing" collection in the memex database.
// Run via: mongosh "$MONGO_URI" ~/shard-listing.js
// Edit dbName/collName/shardKey below as needed - this file is uploaded and
// executed by remote-setup.sh before memex starts, so edits here take
// effect on the next `terraform apply`.

const dbName = "memex";
const collName = "listing";
// Compound range-based shard key: city gives a sensible query isolation
// boundary (queries scoped to a city hit a single shard), _id as the
// tiebreaker ensures uniqueness/monotonic ordering within each city so
// chunks split cleanly. Deliberately not hashed - a hashed key would
// scatter documents randomly and defeat city-scoped query routing.
const shardKey = { city: 1, _id: 1 };

const database = db.getSiblingDB(dbName);

print(`Enabling sharding on database "${dbName}"...`);
sh.enableSharding(dbName);

const existing = database.getCollectionInfos({ name: collName });
if (existing.length === 0) {
  print(`Collection ${dbName}.${collName} does not exist yet - creating it before sharding.`);
  database.createCollection(collName);
}

// MongoDB only auto-creates the supporting shard key index for empty
// collections. If the collection already has data (e.g. after a bulk load),
// the index must be created explicitly first - this is a no-op if an
// equivalent index already exists.
print(`Ensuring supporting index ${JSON.stringify(shardKey)} exists on ${dbName}.${collName}...`);
database[collName].createIndex(shardKey);

print(`Sharding ${dbName}.${collName} with key ${JSON.stringify(shardKey)}...`);
const result = sh.shardCollection(`${dbName}.${collName}`, shardKey);
printjson(result);
