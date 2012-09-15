
node mysql{
   
  class { 'mysql::server':
    config_hash => {
      # the priv grant fails on precise if I set a root password
      # TODO I should make sure that this works
      'root_password' => $mysql_root_password,
      'bind_address'  => '0.0.0.0'
    },
    enabled => $enabled,
  }
  
    # set up all openstack databases, users, grants
  class { 'keystone::db::mysql':
    password => $keystone_db_password,
    allowed_hosts => $keystone_host,
    host => $mysql_host,
  }
  #Class['glance::db::mysql'] -> Class['glance::registry']
  class { 'glance::db::mysql':
    host     => $mysql_host,
    password => $glance_db_password,
  }
  # TODO should I allow all hosts to connect?
  class { 'nova::db::mysql':
    password      => $nova_db_password,
    host          => $mysql_host,
    allowed_hosts => '%',
  }
  exec{"drop":
 	command   => "/bin/rm -rf /root/.my.cnf",
 	path      => '/usr/local/sbin:/usr/bin:/usr/local/bin',
 	require   => Class['nova::db::mysql','glance::db::mysql','keystone::db::mysql'],		
  }
}


node keystone{

  ####### KEYSTONE ###########
  class {'mysql::python':
    before => Class['keystone'],
  }

  # set up keystone
  class { 'keystone':
    admin_token  => $keystone_admin_token,
    # we are binding keystone on all interfaces
    # the end user may want to be more restrictive
    bind_host    => '0.0.0.0',
    log_verbose  => $verbose,
    log_debug    => $verbose,
    catalog_type => 'sql',
    enabled      => $enabled,
  }

  # set up keystone database
  # set up the keystone config for mysql
  class { 'keystone::config::mysql':
    host => $mysql_host,
    password => $keystone_db_password,
  }

  if ($enabled) {
    # set up keystone admin users
    class { 'keystone::roles::admin':
      email        => $admin_email,
      password     => $admin_password,
      admin_tenant => $keystone_admin_tenant,
    }
    # set up the keystone service and endpoint
    class { 'keystone::endpoint':
      public_address   => $keystone_host,
      internal_address => $keystone_host,
      admin_address    => $keystone_host,
    }
    # set up glance service,user,endpoint
    class { 'glance::keystone::auth':
      password         => $glance_user_password,
      public_address   => $glance_host,
      internal_address => $glance_host,
      admin_address    => $glance_host,
      #before           => [Class['glance::api'], Class['glance::registry']]
    }
    # set up nova serice,user,endpoint
    class { 'nova::keystone::auth':
      password         => $nova_user_password,
      public_address   => $nova_host,
      internal_address => $nova_host,
      admin_address    => $nova_host,
      #before           => Class['nova::api'],
    }
  }
  ######## END KEYSTONE ##########
}

node glance{
  ######## BEGIN GLANCE ##########
  
  class {'mysql::python':
    before => Class['glance::api'],
  }

  class { 'glance::api':
    log_verbose       => $verbose,
    log_debug         => $verbose,
    auth_type         => 'keystone',
    auth_host         => $keystone_host,
    auth_port         => '35357',
    keystone_tenant   => 'services',
    keystone_user     => 'glance',
    keystone_password => $glance_user_password,
    enabled           => $enabled,
  }
  class { 'glance::backend::file': }

  class { 'glance::registry':
    log_verbose       => $verbose,
    log_debug         => $verbose,
    auth_type         => 'keystone',
    auth_host         => $keystone_host,
    auth_port         => '35357',
    keystone_tenant   => 'services',
    keystone_user     => 'glance',
    keystone_password => $glance_user_password,
    sql_connection    => "mysql://glance:${glance_db_password}@${mysql_host}/glance",
    enabled           => $enabled,
  }
  ######## END GLANCE ###########
}

node controller{
  
  $multi_host=true
  $create_networks = true
  $network_manager = 'nova.network.manager.FlatDHCPManager'
  $network_config = {}
  $num_networks = 1
  $auto_assign_floating_ip = false
  $secret_key = 'dummy_secret_key'
  $cache_server_ip = '127.0.0.1'
  $cache_server_port = '11211'
  $swift = false
  $quantum = false
  $horizon_app_links = false  
  
  ######## BEGIN NOVA ###########

  class { 'nova::volume': enabled => true }

  class { 'nova::volume::iscsi': }
 
  class { 'nova::rabbitmq':
    userid   => $rabbit_user,
    password => $rabbit_password,
    enabled  => $enabled,
  }

  # TODO I may need to figure out if I need to set the connection information
  # or if I should collect it
  class { 'nova':
    sql_connection     => $nova_db,
    # this is false b/c we are exporting
    rabbit_host        => $rabbit_connection,
    rabbit_userid      => $rabbit_user,
    rabbit_password    => $rabbit_password,
    image_service      => 'nova.image.glance.GlanceImageService',
    glance_api_servers => $glance_api_servers,
    verbose            => $verbose,
  }

  class { 'nova::api':
    enabled           => $enabled,
    # TODO this should be the nova service credentials
    #admin_tenant_name => 'openstack',
    #admin_user        => 'admin',
    #admin_password    => $admin_service_password,
    auth_host         => $keystone_host,
    admin_tenant_name => 'services',
    admin_user        => 'nova',
    admin_password    => $nova_user_password,
  }

  class { [
    'nova::cert',
    'nova::consoleauth',
    'nova::scheduler',
    'nova::objectstore',
    'nova::vncproxy'
  ]:
    enabled => $enabled,
  }

  if $multi_host {
    nova_config { 'multi_host':   value => 'True'; }
    $enable_network_service = false
  } else {
    if $enabled == true {
      $enable_network_service = true
    } else {
      $enable_network_service = false
    }
  }

  if $enabled {
    $really_create_networks = $create_networks
  } else {
    $really_create_networks = false
  }
 
  exec{"rm_nova":
        command => "/bin/rm  -rf /etc/nova/nova.conf",
        path => '/usr/local/sbin:/usr/bin:/usr/local/bin',
  }
 
  Exec['rm_nova']->Class['nova::network']
  

  # set up networking
  class { 'nova::network':
    private_interface => $private_interface,
    public_interface  => $public_interface,
    fixed_range       => $fixed_range,
    floating_range    => $floating_range,
    network_manager   => $network_manager,
    config_overrides  => $network_config,
    create_networks   => $really_create_networks,
    num_networks      => $num_networks,
    enabled           => $enable_network_service,
    install_service   => $enable_network_service, 
  }
   

  if $auto_assign_floating_ip {
    nova_config { 'auto_assign_floating_ip':   value => 'True'; }
  }

  exec{"mv_nova":
	command => "/bin/mv /etc/nova/nova1.conf /etc/nova/nova.conf",
	path => '/usr/local/sbin:/usr/bin:/usr/local/bin',
	require => Class[nova::network],
  }
  exec { 'initial-nova-db-sync':
    command     => '/usr/bin/nova-manage db sync',
    require => Exec['mv_nova'],
  }

  Exec['initial-nova-db-sync']->Class['nova::create_ip']

  class{"nova::create_ip":
    fixed_range      => $fixed_range,
    num_networks     => 1,
    create_networks  => $create_networks,
    floating_range   => $floating_range,
  }
  
  ######## End NOVA ###########

  ######## Horizon ########

  # TOOO - what to do about HA for horizon?

  class { 'memcached':
    listen_ip => '127.0.0.1',
  }

  class { 'horizon':
    secret_key => $secret_key,
    cache_server_ip => $cache_server_ip,
    cache_server_port => $cache_server_port,
    swift => $swift,
    quantum => $quantum,
    horizon_app_links => $horizon_app_links,
  }


  ######## End Horizon #####

  class { 'openstack::auth_file':
    admin_password       => $admin_password,
    keystone_admin_token => $keystone_admin_token,
    controller_node      => $controller_node_internal,
  }
}



node /openstack_compute/ {

  class { 'openstack::compute':
    public_interface   => $public_interface,
    private_interface  => $private_interface,
    internal_address   => $ipaddress_eth0,
    libvirt_type       => 'kvm',
    fixed_range        => $fixed_network_range,
    network_manager    => 'nova.network.manager.FlatDHCPManager',
    multi_host         => true,
    sql_connection     => $nova_db,
    nova_user_password => $nova_user_password,
    rabbit_host        => $nova_host,
    rabbit_password    => $rabbit_password,
    rabbit_user        => $rabbit_user,
    glance_api_servers => $glance_api_servers,
    vncproxy_host      => $nova_host,
    vnc_enabled        => true,
    verbose            => $verbose,
    manage_volumes     => false,
    nova_volume        => 'nova-volumes'
  }

}
