#include "for.h"

// Constants
#define NUM_NODES 3
#define MAJORITY 2
#define BUF_SIZE 3
#define INVALID_NODE_ID 255

// Types
mtype { MSG_ELECT_SELF, MSG_YEA, MSG_NAY, MSG_UP, MSG_DOWN };
mtype { SELF, NODE_UP, NODE_DOWN };

// Node state which must be globally visible.
typedef NodeState {
	// State of links to other nodes.
	mtype linkState[NUM_NODES];
	
	// Input message buffer.
	chan msgBuffer = [BUF_SIZE] of {mtype, byte};
	
	bool isMaster = false;
	
	byte electingSelfCountdownTimer = 0;
	
	byte repliedYeaCountdownTimer = 0;
};

// Globally-visible node state for each node.
NodeState GBL_nodeState[NUM_NODES];

// Inline functions
inline broadcastElectSelf(sender) {
	byte targetNode; 
	for (targetNode, 0, NUM_NODES-1) 
		if 
		:: GBL_nodeState[sender].linkState[targetNode] == NODE_UP -> 
			GBL_nodeState[sender].electingSelfCountdownTimer++;
			GBL_nodeState[targetNode].msgBuffer ! MSG_ELECT_SELF, sender; 
		fi 
	rof(targetNode);
}

inline sendYea(sender, receiver, repliedYea) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		GBL_nodeState[sender].repliedYeaCountdownTimer = 1;
		GBL_nodeState[receiver].electingSelfCountdownTimer++;
		GBL_nodeState[receiver].msgBuffer ! MSG_YEA, INVALID_NODE_ID;
	fi
}

inline sendNay(sender, receiver) {
	if 
	:: GBL_nodeState[sender].linkState[receiver] == NODE_UP ->
		GBL_nodeState[receiver].electingSelfCountdownTimer++;
		GBL_nodeState[receiver].msgBuffer ! MSG_NAY, INVALID_NODE_ID;
	fi
}

proctype Node(byte self) {
	// Local node state
    byte nodesUp = 0;
    byte votes = 0;
    bool repliedYea = false;
    bool electingSelf = false;
    bool seesMaster = false;
    
    // Temporaries
    mtype msgType;
    byte node;
    
	do 
	:: repliedYea == true && GBL_nodeState[self].repliedYeaCountdownTimer == 0 ->
		repliedYea = false;
	:: electingSelf == true && GBL_nodeState[self].electingSelfCountdownTimer == 0 ->
		if 
		:: votes >= MAJORITY ->
			GBL_nodeState[self].isMaster = true;
			seesMaster = true;
		fi;
		electingSelf = false;
		votes = 0;
	:: !GBL_nodeState[self].isMaster && !seesMaster && !electingSelf && !repliedYea && (nodesUp >= MAJORITY) ->
		electingSelf = true;
		votes = 1;
		broadcastElectSelf(self);
    :: GBL_nodeState[self].msgBuffer ? msgType, node -> 
    	if
    	:: msgType == MSG_ELECT_SELF ->
    		GBL_nodeState[node].electingSelfCountdownTimer--; 
    		if
			:: !GBL_nodeState[self].isMaster && !seesMaster && !electingSelf && !repliedYea ->
				repliedYea = true;
				sendYea(self, node);
			:: else ->
				sendNay(self, node); 
    		fi
        :: msgType == MSG_UP -> 
        	nodesUp++;
        	if 
    		:: GBL_nodeState[node].isMaster -> seesMaster = true;
        	fi
        :: msgType == MSG_DOWN -> 
        	nodesUp--;
        	if 
    		:: !GBL_nodeState[self].isMaster && GBL_nodeState[node].isMaster -> seesMaster = false;
        	fi
        :: msgType == MSG_YEA ->
			GBL_nodeState[self].electingSelfCountdownTimer--;
			GBL_nodeState[node].repliedYeaCountdownTimer--;
  			votes++;
        :: msgType == MSG_NAY ->
			GBL_nodeState[self].electingSelfCountdownTimer--;
        fi
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
			GBL_nodeState[node1].msgBuffer ! MSG_UP(node2);
			GBL_nodeState[node2].msgBuffer ! MSG_UP(node1);
			
		:: GBL_nodeState[node1].linkState[node2] == NODE_UP ->
			GBL_nodeState[node1].linkState[node2] = NODE_DOWN;
			GBL_nodeState[node2].linkState[node1] = NODE_DOWN;
			GBL_nodeState[node1].msgBuffer ! MSG_DOWN(node2);
			GBL_nodeState[node2].msgBuffer ! MSG_DOWN(node1);
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

	

