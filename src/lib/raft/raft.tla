/*
 * Copyright 2010-2020, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

--------------------------------- MODULE raft ---------------------------------

EXTENDS Integers, Bags, FiniteSets, Sequences, TLC

CONSTANTS
    Servers,           \* A nonempty set of server identifiers.
    ElectionQuorum,    \* The number of votes needed to elect a leader.
    MaxClientRequests, \* The max number of ClientRequests, -1 means unlimited.
    SplitBrainCheck    \* Whether SplitBrain errors should be raised. TRUE/FALSE

ASSUME Cardinality(Servers) > 0
ASSUME /\ ElectionQuorum \in Nat
       /\ ElectionQuorum < Cardinality(Servers)
ASSUME MaxClientRequests \in Int
ASSUME SplitBrainCheck \in {TRUE, FALSE}

-------------------------------------------------------------------------------
\* Definitions
-------------------------------------------------------------------------------

\* See raft's state variable.
Follower == "FOLLOWER"
Candidate == "CANDIDATE"
Leader == "LEADER"

\* XrowEntry types.
DmlType == "INSERT"
PromoteType == "PROMOTE"
ConfirmType == "CONFIRM"
RollbackType == "ROLLBACK"
RaftType == "RAFT"
OkType == "OK"
NopType == "NOP"

\* Group IDs of the XrowEntry.
DefaultGroup == "DEFAULT"
LocalGroup == "LOCAL"

\* Flags of the XrowEntry:
\* - wait_sync - true for any transaction, that would enter the limbo.
\* - wait_ack - true for a synchronous transaction.
DefaultFlags == [wait_sync |-> FALSE, wait_ack |-> FALSE] \* Async.
SyncFlags == [wait_sync |-> TRUE, wait_ack |-> TRUE]

\* Type of cbus messages to Tx thread.
TxWalType == "WAL"
TxRelayType == "RELAY"
TxApplierType == "APPLIER"

\* See msgs variable for description.
RelaySource == 1
ApplierSource == 2

\* Error codes.
SplitBrainError == "SPLIT_BRAIN"

\* Reserved value
Nil == "NIL"

-------------------------------------------------------------------------------
\* Global variables
-------------------------------------------------------------------------------

\* msgs[sender][receiver][source]. Source is needed, since every instance
\* has 2 connections: first - relay, second - applier. So source = 1 means
\* that msg was written by relay, 2 - by applier. Relay writes to 1, reads
\* from 2. Applier writes to 2, reads from 1.
VARIABLE msgs

-------------------------------------------------------------------------------
\* Per-server variables (operators with server argument)
-------------------------------------------------------------------------------

\* Tx thread implementation.
VARIABLES
    tId,            \* A sequentially growing transaction id (abstraction).
    vclock,         \* Vclock of the current instance.
    txQueue,        \* Queue from any thread (except applier) to TX.
    txApplierQueue, \* Queue from applier thread to Tx. Applier needs separate
                    \* one, since it's crucial, that the write of synchro
                    \* request is synchronous and none of the new entries
                    \* are processed until this write is completed.
    error           \* Critical error on the instance.

\* WAL implementation
VARIABLES
    wal,      \* Sequence of log entries, persisted in WAL.
    walQueue  \* Queue from TX thread to WAL.

\* Limbo implementation.
VARIABLES
    limbo,                     \* Sequence of not yet confirmed entries.
    limboVclock,               \* How owner LSN is visible on other nodes.
    limboOwner,                \* Owner of the limbo as seen by server.
    limboPromoteGreatestTerm,  \* The biggest promote term seen.
    limboPromoteTermMap,       \* Latest terms received with PROMOTE entries.
    limboConfirmedLsn,         \* Maximal quorum lsn that has been persisted.
    limboVolatileConfirmedLsn, \* Not yet persisted confirmedLsn.
    limboConfirmedVclock,      \* Biggest known confirmed lsn for each owner.
    limboAckCount,             \* Number of ACKs for the first txn in limbo.
    limboSynchroMsg,           \* Synchro request to write.
    limboPromoteLatch          \* Order access to the promote data.

\* Raft implementation.
VARIABLES
    state,                \* {"Follower", "Candidate", "Leader"}.
    term,                 \* The current term number of each node.
    volatileTerm,         \* Not yet persisted term.
    vote,                 \* Node vote in its term.
    volatileVote,         \* Not yet persisted vote.
    leader,               \* The leader as known by node.
    votesReceived,        \* The number of votes candidate has received.
    leaderWitnessMap,     \* A bitmap of sources, which see leader in this term.
    isBroadcastScheduled, \* Whether state should be broadcasted to other nodes.
    candidateVclock       \* Vclock of the candidate for which node is voting.

\* Replication implementation.
VARIABLES
    relaySentLsn,  \* Last sent LSN to the peer. See relay->r->cursor.
    relayLastAck,  \* Last received ack from replica.
    relayRaftMsg,  \* Raft message for broadcast.
    applierAckMsg, \* Whether applier needs to send acks.
    applierVclock  \* Implementation of the replicaset.applier.vclock

\* Auxiliary variables.
VARIABLES
    clientCtr, \* The number of done ClientRequests
    debugCtr

txVars == <<tId, vclock, txQueue, txApplierQueue, error>>
walVars == <<wal, walQueue>>
limboVars == <<limboVclock, limboOwner, limboPromoteGreatestTerm,
               limboPromoteTermMap, limboConfirmedLsn, limboConfirmedVclock,
               limboVolatileConfirmedLsn, limboAckCount, limboSynchroMsg,
               limboPromoteLatch>>
raftVars == <<state, term, volatileTerm, vote, volatileVote, leader,
              votesReceived, leaderWitnessMap, isBroadcastScheduled,
              candidateVclock>>
replicationVars == <<relaySentLsn, relayLastAck, relayRaftMsg,
                     applierAckMsg, applierVclock>>
auxVars == <<clientCtr, debugCtr>>
vars == <<msgs, txVars, walVars, limbo, limboVars, raftVars,
          replicationVars, auxVars>>

-------------------------------------------------------------------------------
\* General helper operators
-------------------------------------------------------------------------------

\* Helper for bumping vclock. Given a `bag` of any kind (see Bag standard
\* module) and entry `e`, return a new bag with `v` more `e` in it.
BagAdd(bag, e, v) ==
    IF e \in DOMAIN bag
    THEN [bag EXCEPT ![e] = bag[e] + v]
    ELSE bag @@ (e :> v)

BagAssign(bag, e, v) ==
    (e :> v) @@ bag

\* Compare two bags b1 and b2.
\* Returns:
\*   0  if for all s in Servers b1[s] = b2[s]
\*   1  if for all s in Servers b1[s] >= b2[s] and b1 differs in at least one s
\*  -1  otherwise
BagCompare(b1, b2) ==
    IF \A s \in Servers: b1[s] >= b2[s]
    THEN IF \A s \in Servers: b1[s] = b2[s] THEN 0 ELSE 1
    ELSE -1

BagCountLess(b, x) ==
    Len({i \in DOMAIN b: b[i] < x})

BagCountLessEqual(b, x) ==
    Len({i \in DOMAIN b: b[i] <= x})

\* kth order statistic of the bag.
BagNthElement(b, k) ==
    LET idx == CHOOSE x \in DOMAIN b:
                   /\ BagCountLess(b, x) <= k
                   /\ BagCountLessEqual(b, x) > k
    IN b[idx]

Send(i, j, source, xrow) ==
    LET newMsgs == Append(msgs[i][j][source], xrow)
    IN msgs' = [msgs EXCEPT ![i][j][source] = newMsgs]

-------------------------------------------------------------------------------
\* General structure declarations
-------------------------------------------------------------------------------

\* Return xrow entry. It's written to WAL and replicated.
\* LSN is assigned during WalProcess.
\*  - `xrowType` is DmlXrowType/RaftXrowType/SynchroXrowType;
\*  - `replica_id` is id of the replica which made xrow.
\*  - `groupId` is DefaultGroup/LocalGroup;
\*  - `body` is any function, depends on `xrowType`.
XrowEntry(xrowType, replica_id, groupId, flags, body) == [
    type |-> xrowType,
    replica_id |-> replica_id,
    group_id |-> groupId,
    lsn |-> -1,
    flags |-> flags,
    body |-> body
]

XrowEntryIsGlobal(e) ==
    IF e.group_id = DefaultGroup THEN TRUE ELSE FALSE

\* LSN of the last entry in the log or 0 if the log is empty.
LastLsn(xlog) ==
    IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].lsn

\* Entry, which is sent to WAL thread. Entry cannot have rows of different
\* types (abstraction). Put in walQueue.
\*  - `rows` is a sequence of XrowEntries, which are written to wal, non empty;
\*  - `txn` is either created by TxnBegin or Nil.
JournalEntry(rows, txn) == [
    rows |-> rows,
    \* Txn is complete_data in struct journal_entry. Used to assign
    \* LSNs to limbo after entry is written. rows are written explicitly.
    complete_data |-> txn
]

\* Msg from any thread to Tx thread. Put in TxQueue. Abstraction to process
\* different Tx events.
TxMsg(txEntryType, body) == [
    type |-> txEntryType,
    body |-> body
]

\* Used in applierAckMsg and relayRaftMsg, limboSynchroMsg.
GeneralMsg(body) == [
    is_ready |-> TRUE,
    body |-> body
]

MoreCmp(a, b) == a > b
EqualCmp(a, b) == a = b

FirstEntryLsnIdx(w, lsn, Op(_), Cmp(_, _)) ==
    IF \E k \in 1..Len(w) : Cmp(Op(w[k]), lsn)
    THEN CHOOSE k \in 1..Len(w) : Cmp(Op(w[k]), lsn)
    ELSE -1

FirstEntryMoreLsnIdx(w, lsn, Op(_)) ==
    FirstEntryLsnIdx(w, lsn, Op, MoreCmp)

FirstEntryEqualLsnIdx(w, lsn, Op(_)) ==
    FirstEntryLsnIdx(w, lsn, Op, EqualCmp)

EmptyVclock == [i \in Servers |-> 0]
EmptyGeneralMsg == [is_ready |-> FALSE, body |-> <<>>]
EmptyAck == XrowEntry(OkType, Nil, DefaultGroup, DefaultFlags,
                      [vclock |-> EmptyVclock, term |-> 0])

-------------------------------------------------------------------------------
\* Initial values for all variables
-------------------------------------------------------------------------------

InitTxVars ==
    /\ tId = [i \in Servers |-> 0]
    /\ vclock = [i \in Servers |-> EmptyVclock]
    /\ txQueue = [i \in Servers |-> << >>]
    /\ txApplierQueue = [i \in Servers |-> << >>]
    /\ error = [i \in Servers |-> Nil]

InitWalVars ==
    /\ wal = [i \in Servers |-> << >>]
    /\ walQueue = [i \in Servers |-> << >>]

InitLimboVars ==
    /\ limbo = [i \in Servers |-> << >>]
    /\ limboVclock = [i \in Servers |-> EmptyVclock]
    /\ limboOwner = [i \in Servers |-> Nil]
    /\ limboPromoteGreatestTerm = [i \in Servers |-> 0]
    /\ limboPromoteTermMap = [i \in Servers |-> [j \in Servers |-> 0]]
    /\ limboConfirmedLsn = [i \in Servers |-> 0]
    /\ limboConfirmedVclock = [i \in Servers |-> EmptyVclock]
    /\ limboVolatileConfirmedLsn = [i \in Servers |-> 0]
    /\ limboAckCount = [i \in Servers |-> 0]
    /\ limboSynchroMsg = [i \in Servers |-> EmptyGeneralMsg]
    /\ limboPromoteLatch = [i \in Servers |-> FALSE]

InitRaftVars ==
    /\ state = [i \in Servers |-> "Follower"]
    /\ term = [i \in Servers |-> 1]
    /\ volatileTerm = [i \in Servers |-> 1]
    /\ vote = [i \in Servers |-> Nil]
    /\ volatileVote = [i \in Servers |-> Nil]
    /\ leader = [i \in Servers |-> Nil]
    /\ votesReceived = [i \in Servers |-> 0]
    /\ leaderWitnessMap = [i \in Servers |-> [j \in Servers |-> FALSE]]
    /\ isBroadcastScheduled = [i \in Servers |-> FALSE]
    /\ candidateVclock = [i \in Servers |-> EmptyVclock]

InitReplicationVars ==
    /\ relayLastAck = [i \in Servers |-> [j \in Servers |-> EmptyAck]]
    /\ relaySentLsn = [i \in Servers |-> [j \in Servers |-> 0]]
    /\ relayRaftMsg = [i \in Servers |-> EmptyGeneralMsg]
    /\ applierAckMsg = [i \in Servers |-> EmptyGeneralMsg]
    /\ applierVclock = [i \in Servers |-> EmptyVclock]

InitAuxVars ==
    /\ clientCtr = 0
    /\ debugCtr = 0

Init == /\ msgs = [i \in Servers |-> [j \in Servers |-> [k \in 1..2 |-> <<>>]]]
        /\ InitTxVars
        /\ InitWalVars
        /\ InitLimboVars
        /\ InitRaftVars
        /\ InitReplicationVars
        /\ InitAuxVars

-------------------------------------------------------------------------------
\* Limbo (part 1)
-------------------------------------------------------------------------------
\* TLA+ doesn't support any forward declaration.

LimboIsInRollback(i) ==
    \/ limboSynchroMsg[i] # EmptyGeneralMsg
    \/ limboPromoteLatch[i] = TRUE

\* txn_limbo_confirm.
LimboConfirm(i, newLimbo, newVclock) ==
    IF ~LimboIsInRollback(i)
    THEN LET k == Cardinality(Servers) - ElectionQuorum
             confirmLsn == BagNthElement(newVclock, k)
             idx == CHOOSE x \in Len(newLimbo)..1 :
                  /\ x.stmts[Len(x.stmts)].lsn # -1
                  /\ x.stmts[Len(x.stmts)].lsn <= confirmLsn
             maxAssignedLsn == newLimbo[idx]
             newAckCount == IF idx + 1 > Len(newLimbo) THEN 0
                            ELSE IF newLimbo[idx + 1].stmts[1].lsn = -1 THEN 0
                                 ELSE newLimbo[idx + 1].stmts[1].lsn
         IN /\ limboVolatileConfirmedLsn' =
                  [limboVolatileConfirmedLsn EXCEPT ![i] = maxAssignedLsn]
            /\ limboAckCount' = [limboAckCount EXCEPT ![i] = newAckCount]
    ELSE UNCHANGED <<limboVolatileConfirmedLsn, limboAckCount>>

\* txn_limbo_ack.
LimboAck(i, newLimbo, source, lsn) ==
    IF /\ limboOwner[i] = i
       /\ Len(newLimbo[i]) > 0
       /\ lsn > limboVclock[i][source]
    THEN LET newVclock == BagAssign(limboVclock[i], source, lsn)
         IN /\ limboVclock' = [limboVclock EXCEPT ![i] = newVclock]
            /\ IF /\ newLimbo[i][1].lsn # -1
                  /\ newLimbo[i][1].lsn <= lsn
               THEN LET incAckCount == limboAckCount[i] + 1
                    IN IF limboAckCount[i] + 1 > ElectionQuorum
                       THEN LimboConfirm(i, newLimbo, newVclock)
                       ELSE /\ limboAckCount' =
                                   [limboAckCount EXCEPT ![i] = incAckCount]
                            /\ UNCHANGED <<limboVolatileConfirmedLsn>>
               ELSE UNCHANGED <<limboAckCount, limboVolatileConfirmedLsn>>
    ELSE UNCHANGED <<limboVclock>>

-------------------------------------------------------------------------------
\* Transaction processing
-------------------------------------------------------------------------------

\* Implementation of the txn_begin.
TxnBegin(i, stmts) ==
    \* id is fully abstractional and is not represented in real code. it's
    \* used in order to identify the transaction in the limbo. Note,
    \* that it's not tsn, which must be assigned during WalProcess, but it
    \* won't be, since it's not needed in TLA for now.
    LET id == tId[i] + 1
    IN [id |-> id, stmts |-> stmts]

\* Implementation of the txn_commit_impl for synchronous tx.
\* Adds entry to the limbo and sends it to the WAL thread for writing,
\* where it's processed by WalProcess operator.
TxnCommit(i, txn) ==
    LET \* Set wait_sync flag if limbo is not empty.
        newStmts == IF /\ Len(limbo[i]) > 0
                       /\ txn.stmts[1].group_id # LocalGroup
                       /\ txn.stmts[1].type # NopType
                    THEN [j \in 1..Len(txn.stmts) |-> [txn.stmts[j]
                          EXCEPT !.flags = [txn.stmts[j].flags
                          EXCEPT !.wait_sync = TRUE]]]
                    ELSE txn.stmts
        newTxn == [txn EXCEPT !.stmts = newStmts]
        entry == JournalEntry(txn.stmts, newTxn)
        newWalQueue == Append(walQueue[i], entry)
        newLimbo == IF newStmts[1].flags.wait_sync = TRUE
                    THEN Append(limbo[i], newTxn)
                    ELSE limbo[i]
        doWrite == \/ newStmts[1].flags.wait_sync = FALSE
                   \/ ~LimboIsInRollback(i) \* limbo_is_in_rollback.
    IN IF doWrite
       THEN /\ walQueue' = [walQueue EXCEPT ![i] = newWalQueue]
            /\ limbo' = [limbo EXCEPT ![i] = newLimbo]
            \* It's impossible to update tId in TxnBegin, since it returns txn.
            /\ tId' = [tId EXCEPT ![i] = @ + 1]
       ELSE UNCHANGED <<walQueue, limbo, tId>>

TxnDo(i, entry) ==
    LET stmts == <<entry>>
    IN TxnCommit(i, TxnBegin(i, stmts))

ClientRequest(i) ==
    /\ IF /\ \/ clientCtr = -1
             \/ clientCtr < MaxClientRequests
          /\ state[i] = Leader
       THEN /\ TxnDo(i, XrowEntry(DmlType, i, DefaultGroup, SyncFlags, {}))
            /\ clientCtr' = clientCtr + 1
       ELSE UNCHANGED <<clientCtr, walQueue, limbo, tId>>
    /\ UNCHANGED <<msgs, limboVars, raftVars, replicationVars, auxVars,
                   vclock, txQueue, txApplierQueue, error, walQueue>>

FindTxnInLimbo(newLimbo, txn) ==
    CHOOSE i \in 1..Len(newLimbo) : newLimbo[i].id = txn.id

\* Implementation of the txn_on_journal_write.
TxnOnJournalWrite(i, entry) ==
    \* Implementation of the txn_on_journal_write. Assign LSNs to limbo entries.
    IF entry.rows[1].flags.wait_sync = TRUE
    THEN LET idx == FindTxnInLimbo(limbo[i], entry.complete_data)
             newLimbo == [limbo[i] EXCEPT ![idx] = entry.complete_data]
         IN /\ limbo' = [limbo EXCEPT ![i] = newLimbo]
            /\ LET row == entry.rows[Len(entry.rows)]
               IN IF row.flags.wait_ack = TRUE
                  THEN LimboAck(i, newLimbo, row.replica_id, row.lsn)
                  ELSE UNCHANGED <<limboVclock, limboVolatileConfirmedLsn,
                                   limboAckCount>>
    ELSE UNCHANGED <<limbo, limboVclock, limboVolatileConfirmedLsn,
                     limboAckCount>>

-------------------------------------------------------------------------------
\* Limbo (part 2)
-------------------------------------------------------------------------------

LimboBegin(i) ==
    limboPromoteLatch' = [limboPromoteLatch EXCEPT ![i] = TRUE]

LimboCommit(i) ==
    limboPromoteLatch' = [limboPromoteLatch EXCEPT ![i] = FALSE]

LimboReqPrepare(i, entry) ==
    limboVolatileConfirmedLsn' =
        [limboVolatileConfirmedLsn EXCEPT ![i] = entry.body.lsn]

\* Part of txn_limbo_req_commit, doesn't include reading written request.
LimboReqCommit(i, entry) ==
    LET t == entry.body.term
        newMap == IF t > limboPromoteTermMap[i] THEN
                  [limboPromoteTermMap[i] EXCEPT ![entry.body.origin_id] = t]
                  ELSE limboPromoteTermMap[i]
        newGreatestTerm == IF t > limboPromoteGreatestTerm[i]
                           THEN t ELSE limboPromoteGreatestTerm[i]
    IN /\ limboPromoteTermMap' = [limboPromoteTermMap EXCEPT ![i] = newMap]
       /\ limboPromoteGreatestTerm' =
            [limboPromoteGreatestTerm EXCEPT ![i] = newGreatestTerm]

LimboIsSplitBrain(i, entry) ==
    /\ SplitBrainCheck = TRUE
    /\ entry.replica_id # limboOwner[i]

LimboRaiseSplitBrainIfNeeded(i, entry) ==
    IF LimboIsSplitBrain(i, entry)
    THEN error[i] = SplitBrainError
    ELSE UNCHANGED <<error>>

\* Part of txn_limbo_req_prepare. Checks whether synchro request can
\* be applied without yields.
LimboReqPrepareCheck(i, entry) ==
    /\ limboPromoteLatch[i] = FALSE
    /\ ~LimboIsSplitBrain(i, entry)
    /\ \/ Len(limbo[i]) = 0
       \/ limbo[i][Len(limbo[i])].stmts[1].lsn # -1

LimboWriteStart(i, entry) ==
    /\ LimboBegin(i)
    /\ LimboReqPrepare(i, entry)
    /\ TxnDo(i, entry)

LimboWriteEnd(i, entry, Read(_, _)) ==
    /\ LimboReqCommit(i, entry)
    /\ Read(i, entry)
    /\ LimboCommit(i)

\* Part of apply_synchro_req.
LimboScheduleWrite(i, entry) ==
    /\ LimboRaiseSplitBrainIfNeeded(i, entry)
    /\ IF /\ ~LimboIsSplitBrain(i, entry)
          /\ LimboReqPrepareCheck(i, entry)
       THEN /\ limboSynchroMsg' =
                    [limboSynchroMsg EXCEPT ![i] = GeneralMsg(entry)]
            /\ UNCHANGED <<tId, walQueue, error, limbo,
                           limboVolatileConfirmedLsn, limboPromoteLatch>>
       ELSE /\ LimboWriteStart(i, entry)
            /\ UNCHANGED <<error, limboSynchroMsg>>

LimboWritePromote(i, lsn) ==
    LET entry == XrowEntry(PromoteType, i, DefaultGroup,
                           DefaultFlags, [
            replica_id |-> limboOwner[i],
            origin_id |-> i,
            lsn |-> lsn,
            term |-> limboPromoteTermMap
        ])
    IN LimboScheduleWrite(i, entry)

\* txn_limbo_write_confirm.
LimboWriteConfirm(i, lsn) ==
    LET entry == XrowEntry(ConfirmType, i, DefaultGroup,
                          DefaultFlags, [
            replica_id |-> limboOwner[i],
            origin_id |-> i,
            lsn |-> lsn,
            term |-> 0
        ])
    IN LimboWriteStart(i, entry)

\* First part of the txn_limbo_read_confirm. It must be splitted, since
\* this part is also used in LimboReadPromote and in TLA+ it's not possible
\* to update the same variable twice in one step (in read_confirm limbo's
\* first several entries are deleted, in read_promote, the whole limbo is
\* cleaned)
LimboReadConfirmLsn(i, lsn) ==
    LET newVclock == BagAssign(limboConfirmedVclock[i], limboOwner[i], lsn)
    IN /\ limboConfirmedLsn' = [limboConfirmedLsn EXCEPT ![i] = lsn]
       /\ limboConfirmedVclock' = [limboConfirmedVclock EXCEPT ![i] = newVclock]

\* Second part of the txn_limbo_read_confirm.
LimboReadConfirmLsnLimbo(i, lsn) ==
    LET startIdx == FirstEntryMoreLsnIdx(limbo[i], lsn,
                                    LAMBDA: txn: txn.stmts[Len(txn.stmts)].lsn)
        newLimbo == SubSeq(limbo[i], startIdx, Len(limbo[i]))
    IN /\ Assert(startIdx > 0, "startIdx is < 0 in LimboReadConfirmLsnLimbo")
       /\ limbo' = [limbo EXCEPT ![i] = newLimbo]

LimboReadConfirm(i, entry) ==
    /\ LimboReadConfirmLsn(i, entry.body.lsn)
    /\ LimboReadConfirmLsnLimbo(i, entry.body.lsn)

LimboReadPromote(i, entry) ==
    /\ LimboReadConfirmLsn(i, entry.body.lsn)
    /\ limbo' = [limbo EXCEPT ![i] = << >>]
    /\ limboOwner' = [limboOwner EXCEPT ![i] = entry.body.origin_id]
    /\ limboVolatileConfirmedLsn =
            [limboVolatileConfirmedLsn EXCEPT ![i] = limboConfirmedLsn[i]]

LimboLastLsn(i) ==
    IF Len(limbo[i]) = 0
    THEN limboConfirmedLsn[i]
    ELSE LET stmts == limbo[Len(limbo[i])].stmts
         IN stmts[Len(stmts)].lsn

LimboPromoteQsync(i) ==
    LET lastLsn == LimboLastLsn(i)
    IN /\ lastLsn # -1 \* wal_sync()
       /\ \A j \in Servers: \* box_wait_limbo_acked()
            /\ j # i
            /\ relayLastAck[i][j].body.vclock[i] >= lastLsn
       /\ LimboWritePromote(i, lastLsn)

LimboBumpConfirmedLsn(i) ==
    IF /\ limboOwner[i] = i
       /\ ~LimboIsInRollback(i)
       /\ limboVolatileConfirmedLsn[i] # limboConfirmedLsn[i]
    THEN LimboWriteConfirm(i, limboVolatileConfirmedLsn[i])
    ELSE UNCHANGED <<tId, walQueue, limbo, limboSynchroMsg,
                     limboVolatileConfirmedLsn, limboPromoteLatch>>

LimboProcess(i) ==
    \/ IF /\ limboSynchroMsg[i].is_ready
          /\ LimboReqPrepareCheck(i, limboSynchroMsg[i])
       THEN /\ LimboWriteStart(i, limboSynchroMsg[i])
            /\ limboSynchroMsg = [limboSynchroMsg EXCEPT ![i] = EmptyGeneralMsg]
       ELSE UNCHANGED <<tId, walQueue, error, limbo, limboSynchroMsg,
                        limboVolatileConfirmedLsn, limboPromoteLatch>>
    \/ LimboBumpConfirmedLsn(i)

-------------------------------------------------------------------------------
\* Raft
-------------------------------------------------------------------------------

RaftScheduleBroadcast(i) ==
    isBroadcastScheduled' = [isBroadcastScheduled EXCEPT ![i] = TRUE]

RaftScheduleNewTerm(i, newTerm) ==
    /\ volatileTerm' = [volatileTerm EXCEPT ![i] = newTerm]
    /\ leader' = [leader EXCEPT ![i] = Nil]
    \* Everyone is a follower until its vote for self is persisted.
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ votesReceived' = [votesReceived EXCEPT ![i] = 0]
    /\ leaderWitnessMap' = [leaderWitnessMap EXCEPT ![i] =
            [j \in Servers |-> FALSE]]
    \* State is changed, broadcast.
    /\ RaftScheduleBroadcast(i)

RaftProcessTerm(i, newTerm) ==
    IF newTerm > volatileTerm[i]
    THEN RaftScheduleNewTerm(i, newTerm)
    ELSE UNCHANGED <<state, volatileTerm, leader, votesReceived,
                     leaderWitnessMap, isBroadcastScheduled>>

RaftScheduleNewVote(i, j, newCandidateVclock) ==
    /\ volatileVote' = [volatileVote EXCEPT ![i] = j]
    /\ candidateVclock' = [candidateVclock EXCEPT ![i] = newCandidateVclock]

\* Implementation of the raft_can_vote_for.
RaftCanVoteFor(i, newCandidateVclock) ==
    BagCompare(newCandidateVclock, vclock[i]) \in {0, 1}

RaftTryNewVote(i, j, newCandidateVclock) ==
    IF RaftCanVoteFor(i, newCandidateVclock)
    THEN RaftScheduleNewVote(i, j, newCandidateVclock)
    ELSE UNCHANGED <<volatileVote, candidateVclock>>

\* Implementation of the raft_sm_election_update.
RaftElectionUpdate(i) ==
    \* Pre-vote protection, everyone must agree, that leader is gone.
    IF \A j \in Servers: leaderWitnessMap[i][j] = FALSE
    THEN /\ RaftScheduleNewTerm(i, term[i] + 1)
         /\ RaftScheduleNewVote(i, i, vclock[i])
    ELSE UNCHANGED <<state, volatileTerm, volatileVote, leader,
                     votesReceived, leaderWitnessMap, isBroadcastScheduled,
                     candidateVclock>>

RaftNotifyIsLeaderSeen(i, source, is_seen) ==
    leaderWitnessMap' = [leaderWitnessMap EXCEPT ![i][source] = is_seen]

\* Server times out and tries to start new election.
\* Implementation of the raft_sm_election_update_cb.
RaftTimeout(i) ==
    \* In Tarantool timer is stopped on leader.
    /\ IF /\ state[i] \in {Follower, Candidate}
       THEN /\ RaftNotifyIsLeaderSeen(i, i, FALSE)
            /\ RaftElectionUpdate(i)
       ELSE UNCHANGED <<state, volatileTerm, volatileVote, leader,
                        votesReceived, leaderWitnessMap, isBroadcastScheduled,
                        candidateVclock>>
    /\ UNCHANGED <<msgs, txVars, walVars, libmo, limboVars, replicationVars,
                   auxVars, term, vote>>

\* Send to WAL if node can vote for the candidate or if only term is changed.
\* Implementation of the raft_worker_io.
RaftWorkerHandleIo(i) ==
    LET xrow == XrowEntry(RaftType, i, LocalGroup, DefaultFlags, [
            term |-> volatileTerm[i],
            vote |-> volatileVote[i]
        ])
        entry == JournalEntry(<<xrow>>, <<>>)
        newWalQueue == Append(walQueue[i], entry)
        voteChanged == volatileVote[i] # vote[i]
        doNotWrite == voteChanged /\ ~RaftCanVoteFor(i, volatileVote[i])
    IN  /\ volatileVote' = IF doNotWrite THEN
                [volatileVote EXCEPT ![i] = Nil] ELSE volatileVote
        /\ candidateVclock' = IF doNotWrite THEN
                [candidateVclock EXCEPT ![i] = EmptyBag] ELSE candidateVclock
        /\ walQueue' = IF ~doNotWrite THEN
                [walQueue EXCEPT ![i] = newWalQueue] ELSE walQueue

RaftBecomeLeader(i) ==
    /\ state' = [state EXCEPT ![i] = Leader]
    /\ leader' = [leader EXCEPT ![i] = i]
    /\ RaftScheduleBroadcast(i)

RaftBecomeCandidate(i) ==
    /\ state' = [state EXCEPT ![i] = Candidate]
    /\ leader' = leader
    /\ RaftScheduleBroadcast(i)

\* Continue implementation of the raft_worker_handle_io.
RaftOnJournalWrite(i, entry) ==
    /\ vote' = [vote EXCEPT ![i] = entry.rows[1].body.vote]
    /\ term' = [term EXCEPT ![i] = entry.rows[1].body.term]
    /\ IF volatileVote[i] = i
       THEN IF ElectionQuorum = 1
            THEN RaftBecomeLeader(i)
            ELSE RaftBecomeCandidate(i)
       ELSE UNCHANGED <<state, leader, isBroadcastScheduled>>

\* Implementation of the raft_worker_handle_broadcast.
RaftWorkerHandleBroadcast(i) ==
    LET xrow == XrowEntry(RaftType, i, DefaultGroup, DefaultFlags, [
            term |-> term[i],
            vote |-> vote[i],
            state |-> state[i],
            leader_id |-> leader[i],
            is_leader_seen |-> leaderWitnessMap[i][i],
            vclock |-> IF state[i] = Candidate THEN vclock[i] ELSE <<>>
        ])
    IN relayRaftMsg' = [j \in Servers |-> TxMsg(TxRelayType, xrow)]

\* Implementation of the box_raft_worker_f.
RaftWorker(i) ==
    /\ \/ IF \/ volatileTerm[i] # term[i]
             \/ volatileVote[i] # vote[i]
          THEN RaftWorkerHandleIo(i)
          ELSE UNCHANGED <<walQueue, volatileVote, candidateVclock>>
       \/ IF isBroadcastScheduled[i] = TRUE
          THEN RaftWorkerHandleBroadcast(i)
          ELSE UNCHANGED <<relayRaftMsg>>
       \/ IF /\ state[i] = Leader
             /\ limboPromoteTermMap[i][i] # term[i]
          THEN LimboPromoteQsync(i)
          ELSE UNCHANGED <<tId, walQueue, error, limbo, limboSynchroMsg,
                           limboVolatileConfirmedLsn, limboPromoteLatch>>
    /\ UNCHANGED <<msgs, limboVars, auxVars, vclock, txQueue, txApplierQueue,
                   wal, state, term, volatileTerm, vote, leader, votesReceived,
                   leaderWitnessMap, isBroadcastScheduled, relaySentLsn,
                   relayLastAck, applierAckMsg, applierVclock>>

RaftProcessHeartbeat(i, source) ==
    /\ source = leader[i]
    /\ leaderWitnessMap' = [leaderWitnessMap EXCEPT ![i][i] = TRUE]
    /\ IF leaderWitnessMap[i][i] = FALSE
       THEN RaftScheduleBroadcast(i)
       ELSE UNCHANGED <<isBroadcastScheduled>>

RaftFollowLeader(i, id) ==
    /\ state' = [state EXCEPT ![i] = Follower]
    /\ leader' = [leader EXCEPT ![i] = id]
    /\ RaftScheduleBroadcast(i)

\* Implementation of the raft_process_msg.
RaftProcessMsg(i, entry) ==
    IF entry.body.term >= volatileTerm[i]
    THEN /\ RaftProcessTerm(i, entry.body.term)
         /\ RaftNotifyIsLeaderSeen(i, entry.replica_id, entry.body.is_leader_seen)
         /\ IF entry.body.vote # 0
            THEN IF state[i] \in {Follower, Leader}
                 THEN IF /\ leader[i] = Nil
                         /\ entry.body.vote # i
                         /\ entry.body.state = Candidate
                         /\ volatileVote[i] = Nil
                      THEN RaftTryNewVote(i, entry.replica_id, entry.body.vclock)
                      ELSE UNCHANGED <<volatileVote, candidateVclock,
                                       votesReceived, state, leader,
                                       isBroadcastScheduled>>
                 ELSE \* state[i] = Candidate
                       /\ entry.body.vote = i
                       /\ votesReceived' = [votesReceived EXCEPT ![i] = @ + 1]
                       /\ /\ votesReceived[i] + 1 >= ElectionQuorum
                          /\ RaftBecomeLeader(i)
            ELSE UNCHANGED << >>
         /\ IF entry.body.state # Leader THEN
                 /\ leader[i] = entry.replica_id
                 /\ leader' = [leader EXCEPT ![i] = Nil]
                 /\ RaftNotifyIsLeaderSeen(i, i, FALSE)
                 /\ RaftScheduleBroadcast(i)
            ELSE \* entry.body.state = Leader
                 /\ leader[i] # entry.replica_id
                 /\ leader[i] = Nil
                 /\ RaftFollowLeader(i, entry.replica_id)
    ELSE UNCHANGED <<state, volatileTerm, leader, votesReceived,
                     leaderWitnessMap, isBroadcastScheduled>>


-------------------------------------------------------------------------------
\* Relay
-------------------------------------------------------------------------------

\* Implementation of the relay_process_wal_event.
RelayProcessWalEvent(i, j) ==
    LET startIdx == FirstEntryMoreLsnIdx(wal[i], relaySentLsn[i][j],
                                         LAMBDA x: x.lsn)
        entries == IF startIdx > 0
                   THEN SubSeq(wal[i], startIdx, Len(wal[i]))
                   ELSE << >>
        globalEntries == SelectSeq(entries, XrowEntryIsGlobal)
        newSentLsn == IF globalEntries = <<>>
                      THEN relaySentLsn[i][j]
                      ELSE LastLsn(globalEntries)
    IN  /\ msgs' = [msgs EXCEPT ![i][j] = msgs[i][j] \o entries]
        /\ relaySentLsn' = [relaySentLsn EXCEPT ![i][j] = newSentLsn]

RelayRaftSend(i, j) ==
    /\ Send(i, j, RelaySource, relayRaftMsg.body)
    /\ LET newMsg == [relayRaftMsg[i] EXCEPT !.is_ready = FALSE]
       IN relayRaftMsg = [relayRaftMsg EXCEPT ![i] = newMsg]

\* Implementation of the relay_reader_f.
RelayRead(i, j) ==
    /\ Len(msgs[j][i][ApplierSource]) > 0
    /\ relayLastAck' = [relayLastAck EXCEPT ![i] =
            Head(msgs[j][i][ApplierSource])]
    /\ msgs' = [msgs EXCEPT ![j][i][ApplierSource] =
            Tail(msgs[j][i][ApplierSource])]

RelaySendHeartbeat(i, j) ==
    /\ Send(i, j, RelaySource, XrowEntry(OkType, i, DefaultGroup, DefaultFlags, [
            vclock |-> vclock[i],
            term |-> term[i]
       ]))
    /\ UNCHANGED Tail(vars) \* Only msgs is changed.

\* Implementation of the relay_check_status_needs_update.
RelayStatusUpdate(i) ==
    LET newTxQueue == Append(txQueue[i], TxMsg(TxRelayType, relayLastAck[i]))
    IN txQueue' = [txQueue EXCEPT ![i] = newTxQueue]

RelayProcess(i, j) ==
    /\ i # j \* No replication to self.
    /\ \/ RelaySendHeartbeat(i, j)
       \/ RelayRead(i, j)
       \/ RelayStatusUpdate(i)
       \/ RelayProcessWalEvent(i, j)
       \/ /\ relayRaftMsg[i].is_ready = TRUE
          /\ RelayRaftSend(i, j)

\* Implementation of the tx_status_update.
TxOnRelayUpdate(i, ack) ==
    /\ RaftProcessTerm(i, ack.body.term)
    /\ LimboAck(i, limbo[i], ack.replica_id, ack.body.vclock[i])
    \* See TxProcess for additional UNCHANGED.
    /\ UNCHANGED <<limboOwner, limboPromoteGreatestTerm,
                   limboPromoteTermMap, limboConfirmedVclock,
                   limboSynchroMsg, limboPromoteLatch>>

-------------------------------------------------------------------------------
\* Applier
-------------------------------------------------------------------------------

\* Implementation of the applier_thread_writer_f
ApplierWrite(i, j) ==
    /\ applierAckMsg[i].is_ready = TRUE
    /\ Send(i, j, ApplierSource, applierAckMsg[i].body)
    /\ LET newMsg == [applierAckMsg[i] EXCEPT ![i].is_ready = FALSE]
       IN applierAckMsg' = [applierAckMsg EXCEPT ![i] = newMsg]

ApplierRead(i, j) ==
    /\ Len(msgs[j][i][RelaySource]) > 0
    /\ LET entry == Head(msgs[j][i][RelaySource])
           newQueue == Append(txApplierQueue[i], TxMsg(TxApplierType, entry))
       IN /\ txApplierQueue' = [txApplierQueue EXCEPT ![i] = newQueue]
          /\ msgs' = [msgs EXCEPT ![j][i][RelaySource] =
                          Tail(msgs[j][i][RelaySource])]

ApplierProcess(i, j) ==
    \/ ApplierWrite(i, j)
    \/ ApplierRead(i, j)

ApplierProcessHeartbeat(i, entry) ==
    RaftProcessHeartbeat(i, entry.replica_id)

ApplierSynchroIsSplitBrain(i, entry) ==
    /\ SplitBrainCheck = TRUE
    /\ limboPromoteTermMap[entry.replica_id] # limboPromoteGreatestTerm[i]
    /\ entry.type = DmlType

\* Part of applier_synchro_filter_tx, raise Split Brain error.
ApplierSynchroRaiseSplitBrainIfNeeded(i, entry) ==
    IF ApplierSynchroIsSplitBrain(i, entry)
    THEN error' = [error EXCEPT ![i] = SplitBrainError]
    ELSE UNCHANGED <<error>>

\* Part of applier_synchro_filter_tx, NOPify entries.
ApplierSynchroNopifyTx(i, entry) ==
    LET skipNopify == /\ limboPromoteTermMap[entry.replica_id] =
                            limboPromoteGreatestTerm[i]
                      /\ \/ entry.type = PromoteType
                         \/ /\ entry.type = ConfirmType
                            /\ entry.body.lsn >
                                limboConfirmedVclock[i][entry.replica_id]
    IN IF skipNopify THEN entry
       ELSE [entry EXCEPT !.type = NopType, !.body = <<>>]

ApplierNotInSynchroWrite(i) ==
    ~LimboIsInRollback(i)

ApplierApplyTx(i, entry) ==
    /\ ApplierSynchroRaiseSplitBrainIfNeeded(i, entry)
    /\ IF /\ ~ApplierSynchroIsSplitBrain(i, entry)
          /\ entry.lsn > applierVclock[i][entry.replica_id]
       THEN LET newEntry == ApplierSynchroNopifyTx(i, entry)
            IN /\ applierVclock = [applierVclock EXCEPT
                                   ![i][entry.replica_id] = newEntry.lsn]
               /\ IF \/ newEntry.type = DmlType
                     \/ newEntry.type = NopType
                  THEN /\ TxnDo(i, newEntry)
                       /\ UNCHANGED <<wal, >>
                  ELSE /\ LimboScheduleWrite(i, newEntry)
                       /\ UNCHANGED <<>>
       ELSE UNCHANGED <<applierVclock>>
    /\ UNCHANGED <<wal, >>

\* Implementation of the applier_process_batch.
TxOnApplierReceive(i, entry) ==
    /\ \/ IF entry.lsn # -1 \* DmlType, PromoteType, ConfirmType
          THEN ApplierApplyTx(i, entry)
          ELSE UNCHANGED <<applierVclock, error>>
       \/ IF entry.type = OkType
          THEN ApplierProcessHeartbeat(i, entry)
          ELSE UNCHANGED <<>>
       \/ IF entry.type = RaftType
          THEN RaftProcessMsg(i, entry)
          ELSE UNCHANGED <<>>
    \* See TxProcess for additional UNCHANGED.
    /\ UNCHANGED <<>>

ApplierSignalAck(i, j, ackVclock) ==
    LET entry == XrowEntry(OkType, i, DefaultGroup, DefaultFlags, [
        vclock |-> ackVclock,
        term |-> term[i]
    ])
    IN applierAckMsg = [applierAckMsg EXCEPT ![i] = GeneralMsg(entry)]

\* Implementation of the applier_on_wal_write. Send acks.
ApplierSignalAckIfNeeded(i, entry, ackVclock) ==
    /\ IF entry.replica_id # i
       THEN ApplierSignalAck(i, entry.replica_id, ackVclock)
       ELSE UNCHANGED <<applierAckMsg>>
    \* See TxProcess, TxOnWrite for additional UNCHANGED.
    /\ UNCHANGED <<relaySentLsn, relayLastAck, relayRaftMsg, applierVclock>>

-------------------------------------------------------------------------------
\* WAL
-------------------------------------------------------------------------------

\* Implementation of the wal_write_to_disk, non failing.
WalProcess(i) ==
    /\ Len(walQueue[i]) > 0
    /\ LET entry == Head(walQueue[i])
           \* Implementation of the wal_assign_lsn.
           newRows == [j \in 1..Len(entry.rows) |->
                [entry.rows[j] EXCEPT !.lsn = IF entry.rows[j].lsn = -1 THEN
                 LastLsn(wal[i]) + j ELSE entry.rows[j].lsn]]
           \* Write to disk.
           newWal == wal[i] \o newRows
           \* Update txn only if it's not Nil.
           newEntry == [entry EXCEPT !.rows = newRows, !.complete_data =
                IF entry.complete_data # <<>> THEN [entry.complete_data EXCEPT
                !.stmts = newRows] ELSE entry.complete_data]
           newTxQueue == Append(txQueue[i], TxMsg(TxWalType, newEntry))
           newWalQueue == Tail(walQueue[i])
       IN /\ wal' = [wal EXCEPT ![i] = newWal] \* write to disk.
          /\ txQueue' = [txQueue EXCEPT ![i] = newTxQueue] \* send msg to Tx.
          /\ walQueue' = [walQueue EXCEPT ![i] = newWalQueue]
    /\ UNCHANGED <<txVars, limboVars, raftVars, replicationVars, auxVars>>

TxOnWrite(i, entry) ==
    LET numGlobalRows == Cardinality({j \in 1..Len(entry.rows) :
             entry.rows[j].group_id = DefaultGroup})
        numLocalRows == Cardinality({j \in 1..Len(entry.rows) :
             entry.rows[j].group_id = LocalGroup})
        \* Update vclock's 0 and i component acording to number of
        \* LocalGroup and LocalGroup rows accordingly.
        newVclock == BagAdd(BagAdd(vclock[i], entry.replica_id,
                            Len(entry.rows)), 0, numLocalRows)
    IN \* Implementation of the tx_complete batch.
       /\ vclock' = [vclock EXCEPT ![i] = newVclock]
       /\ \/ /\ entry.rows[1].type = DmlType
             /\ TxnOnJournalWrite(i, entry)
             /\ ApplierSignalAckIfNeeded(i, entry, newVclock)
             /\ UNCHANGED <<raftVars>>
          \/ /\ entry.rows[1].type = ConfirmType
             /\ LimboWriteEnd(i, entry.rows[1], LimboReadConfirm)
             /\ ApplierSignalAckIfNeeded(i, entry, newVclock)
             /\ UNCHANGED <<raftVars>>
          \/ /\ entry.rows[1].type = PromoteType
             /\ LimboWriteEnd(i, entry.rows[1], LimboReadPromote)
             /\ ApplierSignalAckIfNeeded(i, entry, newVclock)
             /\ UNCHANGED <<raftVars>>
          \/ /\ entry.rows[1].type = RaftType
             /\ RaftOnJournalWrite(i, entry)
             /\ UNCHANGED <<limboVars>>

-------------------------------------------------------------------------------
\* Process cbus from to Tx thread. In TLA it's not possible to yield and wait
\* for end of writing to disk e.g, so it's processed as a separate step.
-------------------------------------------------------------------------------

TxProcess(i) ==
    /\ \/ IF Len(txQueue[i]) > 0
          THEN LET entry == Head(txQueue[i])
                   newQueue == Tail(txQueue[i])
               IN /\ txQueue' = [txQueue EXCEPT ![i] = newQueue]
                  /\ \/ /\ \/ entry.type = TxWalType
                           \/ entry.type = PromoteType
                           \/ entry.type = ConfirmType
                        /\ TxOnWrite(i, entry.body)
                     \/ /\ entry.type = TxRelayType
                        /\ TxOnRelayUpdate(i, entry.body)
                  /\ UNCHANGED <<walVars, tId, txQueue, txApplierQueue, error>>
          ELSE UNCHANGED <<txQueue>>
        \/ IF /\ Len(txApplierQueue[i]) > 0
              /\ ApplierNotInSynchroWrite(i)
           THEN LET entry == Head(txApplierQueue[i])
                    newQueue == Tail(txApplierQueue[i])
                IN /\ txApplierQueue' = [txApplierQueue EXCEPT ![i] = newQueue]
                   /\ TxOnApplierReceive(i, entry.body)
                   /\ UNCHANGED <<vclock, txQueue>>
           ELSE UNCHANGED <<txApplierQueue>>
    /\ UNCHANGED <<msgs, auxVars>>

-------------------------------------------------------------------------------
\* Specification
-------------------------------------------------------------------------------

AliveServers == {i \in Servers : error[i] = Nil}

\* Defines how the variables may transition.
Next ==
    \* TX thread.
    \/ \E i \in AliveServers : RaftTimeout(i)
    \/ \E i \in AliveServers : RaftWorker(i)
    \/ \E i \in AliveServers : TxProcess(i)
    \/ \E i \in AliveServers : LimboProcess(i)
    \/ \E i \in AliveServers : ClientRequest(i)
    \* WAL thread.
    \/ \E i \in AliveServers : WalProcess(i)
    \* Relay threads (from i to j)
    \/ \E i,j \in AliveServers : RelayProcess(i, j)
    \* Applier threads (from j to i).
    \/ \E i,j \in AliveServers : ApplierProcess(i, j)

\* Start with Init and transition according to Next. By specifying WF (which
\* stands for Weak Fairness) we're including the requirement that the system
\* must eventually take a non-stuttering step whenever one is possible.
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-------------------------------------------------------------------------------
\* Invariants
-------------------------------------------------------------------------------

BothLeader( i, j ) ==
    /\ i # j
    /\ term[i] = term[j]
    /\ state[i] = Leader
    /\ state[j] = Leader

MoreThanOneLeader ==
    \E i, j \in AliveServers: BothLeader(i, j)

DebugCtr == debugCtr < 5

===============================================================================

Follow-ups:
    * Restart, requires implementation of the SUBSCRIBE, since
      cursor on relay is not up to date. Can update sentLsn explicitly!
    * Reconfiguration of a replicaset: add/remove replicas:
        - Probably requires implementation of the JOIN, SUBSCRIBE,
          snapshots, xlogs.

TODO:
    * WIP UNCHANGED RaftWorker
    * FIX MESSAGES! One message for every applier, relay. Now one for all
      relays, appliers.
    * FIX votesReceived, must be set in order to make votes unique.
