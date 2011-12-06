#include "for.h"

// Constants
#define NUM_NODES 3
#define MAJORITY 2
#define MSG_BUF_SIZE 3
#define INVALID_NODE_ID 255

#define SIMULATED_TIMERS 1

#define EVENT_QUEUE_PARTITIONS 3
#define EVENT_QUEUE_PARTITION_SIZE 5

#define REPLIED_YEA_TIMEOUT_PERIOD 2
#define ELECTING_SELF_TIMEOUT_PERIOD 1

// Types
mtype { MSG_ELECT_SELF, MSG_YEA, MSG_NAY};
mtype { SELF, NODE_UP, NODE_DOWN };
mtype { REPLIED_YEA_TIMEOUT, ELECTING_SELF_TIMEOUT };

// Node state which must be globally visible.
typedef NodeState {
	// State of links to other nodes.
	mtype linkState[NUM_NODES];
	
	bool isMaster = false;
	
	bool seesMaster = false;
	
	byte nodesUp = 0;
};

// Globally-visible node state for each node.
NodeState GBL_nodeState[NUM_NODES];

chan GBL_eventQueuePartitions[EVENT_QUEUE_PARTITIONS] = [EVENT_QUEUE_PARTITION_SIZE] of {mtype, byte, byte};

byte GBL_currentPartitionIndex = 0;

#define CURRENT_EVENT_PARTITION GBL_eventQueuePartitions[GBL_currentPartitionIndex]

#define OFFSET_EVENT_PARTITION(offset) GBL_eventQueuePartitions[(GBL_currentPartitionIndex + offset) % EVENT_QUEUE_PARTITIONS]

// Inline functions
inline propagateState() {
	byte psNode1;
	byte psNode2;
	for (psNode1, 0, NUM_NODES-1)
		GBL_nodeState[psNode1].seesMaster = GBL_nodeState[psNode1].isMaster;
		GBL_nodeState[psNode1].nodesUp = 0;
		for (psNode2, 0, NUM_NODES-1)
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

inline sendYea(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		CURRENT_EVENT_PARTITION ! MSG_YEA(receiver, INVALID_NODE_ID);
	:: else -> ;
	fi;
#ifdef SIMULATED_TIMERS
	OFFSET_EVENT_PARTITION(REPLIED_YEA_TIMEOUT_PERIOD) ! REPLIED_YEA_TIMEOUT(sender, INVALID_NODE_ID);
#endif
}

inline sendNay(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		CURRENT_EVENT_PARTITION ! MSG_NAY(receiver, INVALID_NODE_ID);
	:: else -> ;
	fi
}

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
	OFFSET_EVENT_PARTITION(ELECTING_SELF_TIMEOUT_PERIOD) ! ELECTING_SELF_TIMEOUT(sender, INVALID_NODE_ID);
#endif
}

proctype Node(byte self) {
	// Local node state
    byte votes = 0;
    bool repliedYea = false;
    bool electingSelf = false;
    
    // Temporaries
    byte node;
    
	do 
#ifdef SIMULATED_TIMERS
	:: atomic { CURRENT_EVENT_PARTITION ?? REPLIED_YEA_TIMEOUT, eval(self), _ ->
#else 
	:: atomic { repliedYea == true ->
#endif
		repliedYea = false;
	}
#ifdef SIMULATED_TIMERS
	:: atomic { CURRENT_EVENT_PARTITION ?? ELECTING_SELF_TIMEOUT, eval(self), _ ->
#else 
	:: atomic { electingSelf == true ->
#endif
		if 
		:: votes >= MAJORITY ->
			GBL_nodeState[self].isMaster = true;
		:: else -> ;
		fi;
		electingSelf = false;
		votes = 0;
		propagateState();
	}
	:: atomic { !GBL_nodeState[self].isMaster && !GBL_nodeState[self].seesMaster && !electingSelf && !repliedYea && 
			GBL_nodeState[self].nodesUp >= MAJORITY ->
		electingSelf = true;
		votes = 1;
		broadcastElectSelf(self);
	}
    :: atomic { CURRENT_EVENT_PARTITION ?? MSG_ELECT_SELF, eval(self), node -> 
		if
		:: !GBL_nodeState[self].isMaster && !GBL_nodeState[self].seesMaster && !electingSelf && !repliedYea ->
			repliedYea = true;
			sendYea(self, node);
		:: else ->
			sendNay(self, node); 
		fi
	} 
    :: atomic { CURRENT_EVENT_PARTITION ?? MSG_YEA, eval(self), _ -> 
  		votes++;
  	}
    :: atomic { CURRENT_EVENT_PARTITION ?? MSG_NAY, eval(self), _ ->
    	;
    } 
	od
}

proctype Clock() {
	do 
	:: atomic { empty(CURRENT_EVENT_PARTITION) ->
		GBL_currentPartitionIndex = (GBL_currentPartitionIndex + 1) % EVENT_QUEUE_PARTITIONS;
	}
	od
}

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
	
init {
	byte node1;
	byte node2;

	atomic {
		// Initialize link states.
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

		for (node1, 0, NUM_NODES-1)
			run Node(node1);
		rof(node1)
	}
}

	

