#include "for.h"

#define NUM_NODES 3
#define MAJORITY 2
#define BUF_SIZE 3

mtype { MSG_ELECT_SELF, MSG_UP, MSG_DOWN };
mtype { SELF, NODE_UP, NODE_DOWN };

chan GBL_msgBuffer[NUM_NODES] = [BUF_SIZE] of {mtype, byte};

typedef NodeState {
	bool isMaster = false;
	byte electingSelfTimer = 0;
	byte repliedYeaTimer = 0;
};

NodeState GBL_nodeState[NUM_NODES];

#define checkSeesMaster(linkState, seesMaster) \
	for (node, 0, NUM_NODES-1) \
		if :: linkState[node] == NODE_UP && GBL_nodeState[node].isMaster -> seesMaster = true; break; fi \
	rof(node);
	
#define broadcast(linkState, msg) \
	for (node, 0, NUM_NODES-1) \
		if :: linkState[node] == NODE_UP -> GBL_msgBuffer[node] ! msg; fi \
	rof(node);
		

proctype Node(byte self) {
    byte nodesUp = 0;
    bool repliedYea = false;
    bool electingSelf = false;
    bool seesMaster = false;
    byte node = 0;
    
	mtype linkState[NUM_NODES];
	for (node, 0, NUM_NODES-1)
		if  
		:: node == self -> linkState[node] = SELF;
		:: else -> linkState[node] = NODE_DOWN;
		fi
	rof(node);
	
	do 
	:: repliedYea == true && GBL_nodeState[self].repliedYeaTimer == 0 ->
		repliedYea = false;
	:: electingSelf == true && GBL_nodeState[self].electingSelfTimer == 0 ->
		electingSelf = false;
	:: 
	    select(node: 0 .. NUM_NODES-1);
		if
		:: linkState[node] == NODE_DOWN ->
			linkState[node] = NODE_UP;
			nodesUp++;
			checkSeesMaster(linkState, seesMaster);
		:: linkState[node] == NODE_UP ->
			linkState[node] = NODE_DOWN;
			nodesUp--;
			checkSeesMaster(linkState, seesMaster);
		fi
	:: !GBL_nodeState[self].isMaster && !seesMaster && !electingSelf && !repliedYea ->
		broadcast(linkState, MSG_ELECT_SELF(self));
		 	
	od
		
}

init {
	atomic {
		byte i;
		for (i, 0, NUM_NODES-1)
			run Node(i);
		rof(i);
	}
}

	

