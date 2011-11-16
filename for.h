#define for(I,low,high) \
	I = low ; \
	do \
	:: ( I > high ) -> break \
	:: else -> 
		
#define rof(I) \
	; I++ \
	od

