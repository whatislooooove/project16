#include <amxmod>

public plugin_init()
{
	register_plugin( "HeadShot Blood", "1.1", "tuty" );
	register_event( "DeathMsg", "hook_dead", "a", "3=1" );
}

public hook_dead()
{
	new victim = read_data( 2 );

	new iOrigin[ 3 ];
	get_user_origin( victim, iOrigin );

	message_begin( MSG_PVS, SVC_TEMPENTITY, iOrigin );
	write_byte( TE_BLOODSTREAM );
	write_coord( iOrigin[ 0 ] );
	write_coord( iOrigin[ 1 ] );
	write_coord( iOrigin[ 2 ] + 30 );
	write_coord( random_num( -20, 20 ) );
	write_coord( random_num( -20, 20 ) );
	write_coord( random_num( 50, 300 ) );
	write_byte( 70 );
	write_byte( random_num( 100, 200 ) );
	message_end();

	message_begin( MSG_PVS, SVC_TEMPENTITY, iOrigin );
	write_byte( TE_BLOODSTREAM );
	write_coord( iOrigin[ 0 ] );
	write_coord( iOrigin[ 1 ] );
	write_coord( iOrigin[ 2 ] + 10 );
	write_coord( random_num( -360, 360 ) );
	write_coord( random_num( -360, 360 ) );
	write_coord( -10 );
	write_byte( 70 );
	write_byte( random_num( 50, 100 ) );
	message_end();
}