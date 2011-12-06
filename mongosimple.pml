// A Spin model for the Mongo DB master election protocol.
// Model author: Nick Sawadsky

// for.h defines a macro which emulates a for loop.
#include "for.h"

// Constants
#define NUM_NODES 3
#define MAJORITY 2
#define INVALID_NODE_ID 255

// If set, simulate timers using a partitioned event queue.
#define SIMULATED_TIMERS 1

// Number of partitions in the event queue
#define EVENT_QUEUE_PARTITIONS 3
// Number of events per partition
#define EVENT_QUEUE_PARTITION_SIZE 5

// Timeout for replied yea.  Cannot vote yea for another master candidate
// until this timeout expires.
#define REPLIED_YEA_TIMEOUT_PERIOD 2
// Timeout for electing self.  If majority of votes not received within this
// period, election attempt fails.
#define ELECTING_SELF_TIMEOUT_PERIOD 1

// Messages exchanged betweeen nodes.
mtype { MSG_ELECT_SELF, MSG_YEA, MSG_NAY};

// This type represents the state of a link between two nodes.
mtype { SELF, NODE_UP, NODE_DOWN };

// Messages representing timeout events.
mtype { REPLIED_YEA_TIMEOUT, ELECTING_SELF_TIMEOUT };

// Node state which we need to be globally visible (there is other local state 
// maintained as variables within the Node proctype declaration below).
typedef NodeState {
	// State of links to other nodes (i.e. SELF, NODE_UP, NODE_DOWN).
	mtype linkState[NUM_NODES];
	
	// Does this node believe itself to be the master?
	bool isMaster = false;
	
	// Does this node have a link to another node which believes itself to be master?
	bool seesMaster = false;
	
	// How many other nodes does this node currently have links to?
	byte nodesUp = 0;
};

// Globally-visible node state for each node.
NodeState GBL_nodeState[NUM_NODES];

// We simulate timeouts using a partitioned event queue.  GBL_currentPartitionIndex points to the current partition.
// Within a partition, events and messages are processed in non-deterministic order; but all events and messages in the
// current partition must be processed before we increment GBL_currentPartitionIndex to the next partition.  
// Each event consists of an event or message type, a byte indicating the target node, and optionally a byte indicating the 
// sender node.
chan GBL_eventQueuePartitions[EVENT_QUEUE_PARTITIONS] = [EVENT_QUEUE_PARTITION_SIZE] of {mtype, byte, byte};

byte GBL_currentPartitionIndex = 0;

#define CURRENT_EVENT_PARTITION GBL_eventQueuePartitions[GBL_currentPartitionIndex]

// Find the partition which is 'offset' partitions in the future.  Wrap around from the last partition in the array to the first.
// For this to work correctly, we must ensure that the maximum offset (maximum timeout value) is less than the size of the partition 
// array.  
#define OFFSET_EVENT_PARTITION(offset) GBL_eventQueuePartitions[(GBL_currentPartitionIndex + offset) % EVENT_QUEUE_PARTITIONS]

// Update the nodesUp and seesMaster values for all nodes, based on which nodes currently believe themselves to be master, and
// which node-to-node links are currently up.  Depending on configuration, this function also asserts that only a single node ever
// sees itself as master.
inline propagateState() {
	// ps prefix is necessary to avoid variable name clashes (since inline functions do not have their own scope).
	byte psNode1;
	byte psNode2;
	for (psNode1, 0, NUM_NODES-1)
		GBL_nodeState[psNode1].seesMaster = GBL_nodeState[psNode1].isMaster;
		GBL_nodeState[psNode1].nodesUp = 0;
		for (psNode2, 0, NUM_NODES-1)
			// Assert that we only ever have a single master.  Note that this assertion is only valid when (a) SIMULATED_TIMEOUTS
			// is turned on; and (b) UNRELIABLE_LINKS is turned off.
			assert(psNode1 == psNode2 || !(GBL_nodeState[psNode1].isMaster && GBL_nodeState[psNode2].isMaster)); 
			if 
			:: GBL_nodeState[psNode1].linkState[psNode2] == NODE_UP ->
				GBL_nodeState[psNode1].nodesUp++;
				if 
				:: !GBL_nodeState[psNode1].seesMaster && GBL_nodeState[psNode2].isMaster -> 
					GBL_nodeState[psNode1].seesMaster = true;
				:: else -> ; 
				fi
			:: else -> ;
			fi
		rof(psNode2)
	rof(psNode1);
}

// Send a YEA vote, and set a timer for the period in which this node may not vote for any other master hopeful.
inline sendYea(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		CURRENT_EVENT_PARTITION ! MSG_YEA(receiver, INVALID_NODE_ID);
	:: else -> ;
	fi;
#ifdef SIMULATED_TIMERS
	// Insert the timeout event in the partition which is REPLIED_YEA_TIMEOUT_PERIOD partitions in the future.
	OFFSET_EVENT_PARTITION(REPLIED_YEA_TIMEOUT_PERIOD) ! REPLIED_YEA_TIMEOUT(sender, INVALID_NODE_ID);
#endif
}

// Send a NAY vote.
inline sendNay(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		CURRENT_EVENT_PARTITION ! MSG_NAY(receiver, INVALID_NODE_ID);
	:: else -> ;
	fi
}

// Broadcast a message to request that this node be elected master, and set a timer for the period in which
// the reply messages (votes) must be received.
inline broadcastElectSelf(sender) {
	byte besNode;
	for (besNode, 0, NUM_NODES-1) 
		if 
		:: GBL_nodeState[sender].linkState[besNode] == NODE_UP -> 
			CURRENT_EVENT_PARTITION ! MSG_ELECT_SELF(besNode, sender); 
		:: else -> 
		fi 
	rof(besNode);
#ifdef SIMULATED_TIMERS
	// Insert the timeout event in the partition which is ELECTING_SELF_TIMEOUT_PERIOD partitions in the future.
	OFFSET_EVENT_PARTITION(ELECTING_SELF_TIMEOUT_PERIOD) ! ELECTING_SELF_TIMEOUT(sender, INVALID_NODE_ID);
#endif
}

proctype Node(byte self) {
	// Number of votes this node has received in current election.
    byte votes = 0;
    // Has this node voted for another to become master?
    bool repliedYea = false;
    // Has this node requested to be elected master?
    bool electingSelf = false;
    
    // Temporaries
    byte node;
    
	do
	// Handle the 'replied yea' timeout, indicating this node is now free to vote in another election. 
#ifdef SIMULATED_TIMERS
	:: atomic { CURRENT_EVENT_PARTITION ?? REPLIED_YEA_TIMEOUT, eval(self), _ ->
		assert(repliedYea);
#else 
	// Without simulated timers, reset of the repliedYea flag can occur at any time.
	:: atomic { repliedYea == true ->
#endif
		repliedYea = false;
	}
	// Handle the 'electing self' timeout, indicating the period in which votes can be received for this node's election
	// request has elapsed. 
#ifdef SIMULATED_TIMERS
	:: atomic { CURRENT_EVENT_PARTITION ?? ELECTING_SELF_TIMEOUT, eval(self), _ ->
		assert(electingSelf);
#else 
	:: atomic { electingSelf == true ->
#endif
		if
		// If node received a yea vote from majority of nodes, declare it master. 
		:: votes >= MAJORITY ->
			GBL_nodeState[self].isMaster = true;
		:: else -> ;
		fi;
		electingSelf = false;
		votes = 0;
		propagateState();
	}
	// If all conditions are met, broadcast election request for this node.
	:: atomic { !GBL_nodeState[self].isMaster && !GBL_nodeState[self].seesMaster && !electingSelf && !repliedYea && 
			GBL_nodeState[self].nodesUp >= MAJORITY ->
		electingSelf = true;
		// Node always votes for itself.
		votes = 1;
		broadcastElectSelf(self);
	}
	// Handle election request from another node.
    :: atomic { CURRENT_EVENT_PARTITION ?? MSG_ELECT_SELF, eval(self), node -> 
		if
		// Condition for sending a yea vote:
		:: !GBL_nodeState[self].isMaster && !GBL_nodeState[self].seesMaster && !electingSelf && !repliedYea ->
			repliedYea = true;
			sendYea(self, node);
		:: else ->
			sendNay(self, node); 
		fi
	} 
	// Handle yea vote from another node.
    :: atomic { CURRENT_EVENT_PARTITION ?? MSG_YEA, eval(self), _ ->
    	assert(electingSelf); 
  		votes++;
  	}
  	// Handle nay vote.
    :: atomic { CURRENT_EVENT_PARTITION ?? MSG_NAY, eval(self), _ ->
    	assert(electingSelf);
    } 
	od
}

// If SIMULATED_TIMERS is set, this process is responsible for incrementing the GBL_currentPartitionIndex.
proctype Clock() {
	do 
	// If the current partition is empty, we can increment the partition index.  
	:: atomic { empty(CURRENT_EVENT_PARTITION) ->
		GBL_currentPartitionIndex = (GBL_currentPartitionIndex + 1) % EVENT_QUEUE_PARTITIONS;
	}
	od
}

// If UNRELIABLE_LINKS is set, this process is responsible for breaking and restoring links between nodes.
proctype LinkBreaker() {
	byte node1;
	byte node2;
	do
	:: atomic {
		// Choose a link to break/repair.
		select(node1: 0 .. NUM_NODES-1);
		select(node2: 0 .. NUM_NODES-1);
		if 
		:: GBL_nodeState[node1].linkState[node2] == SELF -> ;

		:: GBL_nodeState[node1].linkState[node2] == NODE_DOWN ->
			GBL_nodeState[node1].linkState[node2] = NODE_UP;
			GBL_nodeState[node2].linkState[node1] = NODE_UP;
			
		:: GBL_nodeState[node1].linkState[node2] == NODE_UP ->
			GBL_nodeState[node1].linkState[node2] = NODE_DOWN;
			GBL_nodeState[node2].linkState[node1] = NODE_DOWN;
		fi;
		propagateState();
	}
	od
}

// Initializes the model.	
init {
	byte node;
	byte node1;
	byte node2;

	atomic {
		// Initially, all links are up.
		for (node1, 0, NUM_NODES-1)
			for (node2, 0, NUM_NODES-1) 
				if  
				:: node1 == node2 -> GBL_nodeState[node1].linkState[node2] = SELF;
				:: else -> GBL_nodeState[node1].linkState[node2] = NODE_UP;
				fi
			rof(node2)
		rof(node1);
		propagateState();
	
#ifdef SIMULATED_TIMERS
		run Clock();
#endif
		
#ifdef UNRELIABLE_LINKS
		run LinkBreaker();
#endif

		// Start the nodes.
		for (node, 0, NUM_NODES-1)
			run Node(node);
		rof(node)
	}
}

	

