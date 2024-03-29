// A Spin model for the Mongo DB master election protocol.
// Model author: Nick Sawadsky

// for.h defines a macro which emulates a for loop.
#include "for.h"

// Constants

// Macro to enable unreliable links
#define UNRELIABLE_LINKS 1

#define NUM_NODES 3
#define MAJORITY 2
#define INVALID_TIMER_VALUE 255
#define INVALID_NODE_ID 255

// Size of each node's input message buffer
#define MSG_BUFFER_SIZE 2

// Timeout for replied yea.  Cannot vote yea for another master candidate
// until this timeout expires.
#define REPLIED_YEA_TIMEOUT 2

// Timeout for electing self.  If majority of votes not received within this
// period, election attempt fails.
#define ELECTING_SELF_TIMEOUT 1

// Messages exchanged betweeen nodes.
mtype { MSG_ELECT_SELF, MSG_YEA, MSG_NAY};

// This type represents the state of a link between two nodes.
mtype { SELF, NODE_UP, NODE_DOWN };

// Node state which we need to be globally visible.
typedef NodeState {
	// Input message buffer for this node.
	chan msgBuffer = [MSG_BUFFER_SIZE] of {mtype, byte}; 
	
	// State of links to other nodes (i.e. SELF, NODE_UP, NODE_DOWN).
	mtype linkState[NUM_NODES];
	
	// Does this node believe itself to be the master?
	bool isMaster = false;
	
	// Does this node have a link to another node which believes itself to be master?
	bool seesMaster = false;
	
	// How many other nodes does this node currently have links to?
	byte nodesUp = 1;
	
	// Timer indicating when this node will be free to vote in another election.
	byte repliedYeaTimer = INVALID_TIMER_VALUE;
	
	// Timer indicating when this node's election expires.
	byte electingSelfTimer = INVALID_TIMER_VALUE;
};

// Is it possible for links to change state?
#ifdef UNRELIABLE_LINKS 
bool GBL_unreliableLinks = true;
#else
bool GBL_unreliableLinks = false;
#endif

// Used for LTL verification.
bool GBL_masterExists = false;

// Used for LTL verification.
bool GBL_moreThanOneMaster = false;

// Used for LTL verification.
bool GBL_node0SeesMajority = false;

// At any point, we can ensure that going forward, only a single node is eligible to become master.
// In LTL verification, we will check that whenever this becomes true, we eventually will have a master.
bool GBL_onlyNode0Eligible = false;

// Globally-visible node state for each node.
NodeState GBL_nodeState[NUM_NODES];

// Update the nodesUp and seesMaster values for all nodes, based on which node-to-node links are currently up and which nodes 
// believe themselves to be master.  Depending on configuration, this function also asserts that we only ever have one node
// which believes itself to be master.
inline propagateState() {
	// ps prefix is necessary to avoid variable name clashes (since inline functions do not have their own scope).
	byte psNode1;
	byte psNode2;
	GBL_masterExists = false;
	GBL_node0SeesMajority = false;
	GBL_moreThanOneMaster = false;
	for (psNode1, 0, NUM_NODES-1)
		if 
		:: GBL_nodeState[psNode1].isMaster ->
			if 
			:: GBL_masterExists ->
				GBL_moreThanOneMaster = true;
			:: else ->
				GBL_masterExists = true;
			fi
		:: else -> ;
		fi;

		GBL_nodeState[psNode1].seesMaster = GBL_nodeState[psNode1].isMaster;
		
		GBL_nodeState[psNode1].nodesUp = 1;
		for (psNode2, 0, NUM_NODES-1)
			// Assert that we only ever have a single master (this is only valid if UNRELIABLE_LINKS is disabled).
#ifndef UNRELIABLE_LINKS  
			assert(psNode1 == psNode2 || !(GBL_nodeState[psNode1].isMaster && GBL_nodeState[psNode2].isMaster));
#endif 
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
		rof(psNode2);
	rof(psNode1);
	if 
	:: GBL_nodeState[0].nodesUp >= MAJORITY ->
		GBL_node0SeesMajority = true;
	:: else -> ;
	fi
}

// Send a YEA vote.
inline sendYea(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		GBL_nodeState[receiver].msgBuffer ! MSG_YEA(sender);
	:: else -> ;
	fi;
}

// Send a NAY vote.
inline sendNay(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		GBL_nodeState[receiver].msgBuffer ! MSG_NAY(sender);
	:: else -> ;
	fi
}

// Broadcast a message to request that this node be elected master.
inline broadcastElectSelf(sender) {
	byte besNode;
	for (besNode, 0, NUM_NODES-1) 
		if 
		:: GBL_nodeState[sender].linkState[besNode] == NODE_UP -> 
			GBL_nodeState[besNode].msgBuffer ! MSG_ELECT_SELF(sender); 
		:: else -> 
		fi 
	rof(besNode);
}

proctype Node(byte self) {
	// Number of votes this node has received in current election.
    byte votes = 0;
    byte repliedYeaTo = INVALID_NODE_ID;
    
    // Temporaries
    byte node;
    
	do
	// Handle the 'replied yea' timeout, indicating this node is now free to vote in another election. 
	:: atomic { GBL_nodeState[self].repliedYeaTimer == 0 ->
		GBL_nodeState[self].repliedYeaTimer = INVALID_TIMER_VALUE;
		repliedYeaTo = INVALID_NODE_ID;
	}
	// Handle the 'electing self' timeout, indicating the period in which votes can be received for this node's election
	// request has elapsed. 
	:: atomic { GBL_nodeState[self].electingSelfTimer == 0 ->
		if
		// If node received a yea vote from majority of nodes, declare it master. 
		:: votes >= MAJORITY ->
			GBL_nodeState[self].isMaster = true;
			printf("== Node %d declares itself master ==\n", self);
		:: else -> ;
		fi;
		GBL_nodeState[self].electingSelfTimer = INVALID_TIMER_VALUE;
		votes = 0;
		propagateState();
	}
	// If all conditions are met, broadcast election request for this node.
	:: atomic { !GBL_nodeState[self].isMaster && !GBL_nodeState[self].seesMaster && 
			GBL_nodeState[self].electingSelfTimer == INVALID_TIMER_VALUE && GBL_nodeState[self].repliedYeaTimer == INVALID_TIMER_VALUE &&  
			GBL_nodeState[self].nodesUp >= MAJORITY && (!GBL_onlyNode0Eligible || self == 0) ->
		// Node always votes for itself.
		votes = 1;
		
		// For added realism, we should release the atomic lock before broadcasting the request, so that
		// this master election broadcast can be interleaved with others (tried it and the state space
		// increases substantially, although still verifiable in 1-2 minutes).
		broadcastElectSelf(self);
		GBL_nodeState[self].electingSelfTimer = ELECTING_SELF_TIMEOUT;
	}
	// Handle election request from another node.
    :: atomic { GBL_nodeState[self].msgBuffer ? MSG_ELECT_SELF, node -> 
		if
		// Condition for sending a yea vote:
		:: !GBL_nodeState[self].isMaster && !GBL_nodeState[self].seesMaster && 
				GBL_nodeState[self].electingSelfTimer == INVALID_TIMER_VALUE && 
				(GBL_nodeState[self].repliedYeaTimer == INVALID_TIMER_VALUE || repliedYeaTo == node) ->
			repliedYeaTo = node;
			sendYea(self, node);
			GBL_nodeState[self].repliedYeaTimer = REPLIED_YEA_TIMEOUT;
		:: else ->
			// Commented out to reduce state space (the receiver does nothing with this message).
			//sendNay(self, node); 
		fi;
		node = 0;
	} 
	// Handle yea vote from another node.
    :: atomic { GBL_nodeState[self].msgBuffer ? MSG_YEA, _ ->
    	assert(GBL_nodeState[self].electingSelfTimer != INVALID_TIMER_VALUE); 
  		votes++;
  	}
  	// Handle nay vote.
    :: atomic { GBL_nodeState[self].msgBuffer ? MSG_NAY, _ ->
    	assert(GBL_nodeState[self].electingSelfTimer != INVALID_TIMER_VALUE);
    } 
    // Handle case where master can no longer see majority of the nodes.
    :: atomic { GBL_nodeState[self].isMaster && GBL_nodeState[self].nodesUp < MAJORITY ->
    	GBL_nodeState[self].isMaster = false;
    	propagateState();
    }
	od
}

// This process is responsible for atomically decrementing all timers, provided no timeouts 
// remain to be processed in the current time slot, and all message queues are empty.
proctype Clock() {
	byte node;
	bool canAdvance;
	do 
	// If message buffers are empty and all timeouts have been processed, we can advance the clock.  
	:: atomic { 
		canAdvance = true;
		for (node, 0, NUM_NODES-1) 
			if
			:: len(GBL_nodeState[node].msgBuffer) > 0 -> 
				canAdvance = false;
				break;
			:: else -> ;
			fi;
			if 
			:: GBL_nodeState[node].electingSelfTimer == 0 ->
				canAdvance = false;
				break;
			:: else -> ;
			fi;
			if 
			:: GBL_nodeState[node].repliedYeaTimer == 0 ->
				canAdvance = false;
				break;
			:: else -> ;
			fi;
		rof(node);
		if 
		:: canAdvance ->
			printf("==== Advancing clock ====\n");
			for (node, 0, NUM_NODES-1) 
				if
				:: GBL_nodeState[node].electingSelfTimer != INVALID_TIMER_VALUE ->
					GBL_nodeState[node].electingSelfTimer--;
				:: else -> ;
				fi;
				if
				:: GBL_nodeState[node].repliedYeaTimer != INVALID_TIMER_VALUE ->
					GBL_nodeState[node].repliedYeaTimer--;
				:: else -> ;
				fi;
			rof(node);
		:: else -> ;
		fi;
		node = 0;
		canAdvance = false;
	}
	od
}

// This process is responsible for, at some point, setting GBL_onlyNode0Eligible to true.
proctype SetUniqueEligibleNode() {
	atomic { 
		GBL_onlyNode0Eligible = true;
	}
}

// If UNRELIABLE_LINKS is set, this process is reponsible for, at some point, setting GBL_unreliableLinks to false.
proctype DisableUnreliableLinks() {
	atomic {
		GBL_unreliableLinks = false;
	}
}

// If UNRELIABLE_LINKS is set, this process is responsible for breaking and restoring links between nodes.
proctype LinkBreaker() {
	byte node1;
	byte node2;
	do
	:: atomic { GBL_unreliableLinks ->
		// Choose a link to break/repair.
		select(node1: 0 .. NUM_NODES-2);
		select(node2: node1+1 .. NUM_NODES-1);
		if 
		:: GBL_nodeState[node1].linkState[node2] == NODE_DOWN ->
			GBL_nodeState[node1].linkState[node2] = NODE_UP;
			GBL_nodeState[node2].linkState[node1] = NODE_UP;
			
		:: GBL_nodeState[node1].linkState[node2] == NODE_UP ->
			GBL_nodeState[node1].linkState[node2] = NODE_DOWN;
			GBL_nodeState[node2].linkState[node1] = NODE_DOWN;
		fi;
		propagateState();
		node1 = 0;
		node2 = 0;
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
	
		run Clock();
		run SetUniqueEligibleNode();
		
#ifdef UNRELIABLE_LINKS
		run LinkBreaker();
		run DisableUnreliableLinks();
#endif

		// Start the nodes.
		for (node, 0, NUM_NODES-1)
			run Node(node);
		rof(node)
	}
}

	

