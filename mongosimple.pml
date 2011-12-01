#include "for.h"

// Constants
#define NUM_NODES 3
#define MAJORITY 2
#define BUF_SIZE 3

// Types
mtype { MSG_ELECT_SELF, MSG_UP, MSG_DOWN };
mtype { SELF, NODE_UP, NODE_DOWN };

// Node state which must be globally visible.
typedef NodeState {
	// State of links to other nodes.
	mtype linkState[NUM_NODES];
	
	bool isMaster = false;
	byte electingSelfTimer = 0;
	byte repliedYeaTimer = 0;
};

// Global variables

// Input message queue for each node.
chan GBL_msgBuffer[NUM_NODES] = [BUF_SIZE] of {mtype, byte};

// Globally-visible node state for each node.
NodeState GBL_nodeState[NUM_NODES];

// Macros (functions)
#define broadcast(sender, msg) \
	byte targetNode;
	for (targetNode, 0, NUM_NODES-1) \
		if :: GBL_nodeState[sender].linkState[targetNode] == NODE_UP -> GBL_msgBuffer[targetNode] ! msg; fi \
	rof(targetNode);
		

proctype Node(byte self) {
	// Local node state
    byte nodesUp = 0;
    bool repliedYea = false;
    bool electingSelf = false;
    bool seesMaster = false;
    
	do 
	:: repliedYea == true && GBL_nodeState[self].repliedYeaTimer == 0 ->
		repliedYea = false;
	:: electingSelf == true && GBL_nodeState[self].electingSelfTimer == 0 ->
		electingSelf = false;
	:: !GBL_nodeState[self].isMaster && !seesMaster && !electingSelf && !repliedYea && (nodesUp >= MAJORITY) ->
		electingSelf = true;
		broadcast(self, MSG_ELECT_SELF(self));
		 	
	od
		
}

proctype LinkBreaker() {
	byte node1;
	byte node2;
	
	// Initially, all links are down.
	for (node1, 0, NUM_NODES-1)
		for (node2, 0, NUM_NODES-1) 
			if  
			:: node1 == node2 -> GBL_nodeState[node1].linkState[node2] = SELF;
			:: else -> GBL_nodeState[node1].linkState[node2] = NODE_DOWN;
			fi
		rof(node2);
	rof(node1);
	
	do
	:: 
		// Choose a link to break/repair.
		select(node1: 0 .. NUM_NODES-1);
		select(node2: 0 .. NUM_NODES-1);
		if 
		:: GBL_nodeState[node1].linkState[node2] == SELF -> ;

		:: GBL_nodeState[node1].linkState[node2] == NODE_DOWN ->
			GBL_nodeState[node1].linkState[node2] = NODE_UP;
			GBL_nodeState[node2].linkState[node1] = NODE_UP;
			GBL_msgBuffer[node1] ! MSG_UP(node2);
			GBL_msgBuffer[node2] ! MSG_UP(node1);
			
		:: GBL_nodeState[node1].linkState[node2] == NODE_UP ->
			GBL_nodeState[node1].linkState[node2] = NODE_DOWN;
			GBL_nodeState[node2].linkState[node1] = NODE_DOWN;
			GBL_msgBuffer[node1] ! MSG_DOWN(node2);
			GBL_msgBuffer[node2] ! MSG_DOWN(node1);
		fi
	od
}
	
init {
	atomic {
		run LinkBreaker();

		byte i;
		for (i, 0, NUM_NODES-1)
			run Node(i);
		rof(i);
	}
}

	

