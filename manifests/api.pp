# == Class: barbican::api
#
# The barbican::api class encapsulates a Barbican API service running
# in a gunicorn container.
#
# === Parameters
#
# [*package_ensure*]
#   (optional) The state of barbican packages
#   Defaults to 'present'
#
# [*client_package_ensure*]
#   (optional) Desired ensure state of the client package.
#   accepts latest or specific versions.
#   Defaults to 'present'.
#
# [*bind_host*]
#   (optional) The IP address of the network interface to listen on
#   Default to '0.0.0.0'.
#
# [*bind_port*]
#   (optional) Port that barbican binds to.
#   Defaults to '9311'
#
# [*host_href*]
#   (optional) The reference that clients use to point back to the service
#   Defaults to http://`hostname`:<bind_port>
#   TODO: needs to be set
#
# [*manage_service*]
#   (optional) If Puppet should manage service startup / shutdown.
#   Defaults to true.
#
# [*enabled*]
#   (optional) Whether to enable services.
#   Defaults to true.
#
# [*auth_strategy*]
#   (optional) authentication type
#   Defaults to 'keystone'
#
# [*service_name*]
#   (optional) Name of the service that will be providing the
#   server functionality of barbican-api.
#   If the value is 'httpd', this means barbican-api will be a web
#   service, and you must use another class to configure that
#   web service. For example, use class { 'barbican::wsgi::apache'...}
#   to make barbican-api be a web app using apache mod_wsgi.
#   Defaults to 'barbican-api'
#
# [*use_ssl*]
#   (optional) Enable SSL on the API server
#   Defaults to false, not set
#
# [*cert_file*]
#   (optinal) Certificate file to use when starting API server securely
#   Defaults to $::os_service_default
#
# [*key_file*]
#   (optional) Private key file to use when starting API server securely
#   Defaults to $::os_service_default
#
# [*ca_file*]
#   (optional) CA certificate file to use to verify connecting clients
#   Defaults to $::os_service_default
#
# [*enable_proxy_headers_parsing*]
#   (Optional) Enable paste middleware to handle SSL requests through
#   HTTPProxyToWSGI middleware.
#   Defaults to $::os_service_default.
#
# [*max_request_body_size*]
#   (Optional) Set max request body size
#   Defaults to $::os_service_default.
#
class barbican::api (
  $package_ensure                                = 'present',
  $client_package_ensure                         = 'present',
  $bind_host                                     = '0.0.0.0',
  $bind_port                                     = '9311',
  $host_href                                     = undef,
  $manage_service                                = true,
  $enabled                                       = true,
  $auth_strategy                                 = 'keystone',
  $use_ssl                                       = false,
  $ca_file                                       = $::os_service_default,
  $cert_file                                     = $::os_service_default,
  $key_file                                      = $::os_service_default,
  $service_name                                  = 'barbican-api',
  $enable_proxy_headers_parsing                  = $::os_service_default,
  $max_request_body_size                         = $::os_service_default,
) inherits barbican::params {

  include barbican::deps
  include barbican::client
  include barbican::policy

  # TODO: Remove the posix users and permissions and merge this definition
  # with the previous one, once the barbican package has been updated
  # with the correct ownership for this directory.
  file { ['/var/lib/barbican']:
    ensure  => directory,
    mode    => '0770',
    owner   => 'root',
    group   => 'barbican',
    require => Anchor['barbican::install::end'],
    notify  => Anchor['barbican::service::end'],
  }

  package { 'barbican-api':
    ensure => $package_ensure,
    name   => $::barbican::params::api_package_name,
    tag    => ['openstack', 'barbican-package'],
  }

  # basic service config
  if $host_href == undef {
    $host_href_real = "http://${::fqdn}:${bind_port}"
  } else {
    $host_href_real = $host_href
  }

  barbican_config {
    'DEFAULT/bind_host': value => $bind_host;
    'DEFAULT/bind_port': value => $bind_port;
    'DEFAULT/host_href': value => $host_href_real;
  }

  # keystone config
  if $auth_strategy == 'keystone' {

    include ::barbican::keystone::authtoken

    barbican_api_paste_ini {
      'pipeline:barbican_api/pipeline': value => 'cors authtoken context apiapp';
    }

  } else {
    barbican_api_paste_ini {
      'pipeline:barbican_api/pipeline': value => 'cors unauthenticated-context apiapp';
    }

    barbican_config {
      'keystone_authtoken/auth_plugin':          ensure => 'absent';
      'keystone_authtoken/auth_type':            ensure => 'absent';
      'keystone_authtoken/www_authenticate_uri': ensure => 'absent';
      'keystone_authtoken/project_name':         ensure => 'absent';
      'keystone_authtoken/username':             ensure => 'absent';
      'keystone_authtoken/password':             ensure => 'absent';
      'keystone_authtoken/user_domain_id':       ensure => 'absent';
      'keystone_authtoken/project_domain_id':    ensure => 'absent';
    }
  }

  if $manage_service {
    if $enabled {
      $service_ensure = 'running'
    } else {
      $service_ensure = 'stopped'
    }
  }

  if $use_ssl {
    if is_service_default($cert_file) {
      fail('The cert_file parameter is required when use_ssl is set to true')
    }
    if is_service_default($key_file) {
      fail('The key_file parameter is required when use_ssl is set to true')
    }
  }

  # SSL Options
  barbican_config {
    'DEFAULT/cert_file': value => $cert_file;
    'DEFAULT/key_file':  value => $key_file;
    'DEFAULT/ca_file':   value => $ca_file;
  }

  if $service_name == 'barbican-api' {
    if $::os_package_type == 'ubuntu' {
      fail('With Ubuntu packages the service_name must be set to httpd as there is no eventlet init script.')
    }
    service { 'barbican-api':
      ensure     => $service_ensure,
      name       => $::barbican::params::api_service_name,
      enable     => $enabled,
      hasstatus  => true,
      hasrestart => true,
      tag        => 'barbican-service',
    }

    file_line { 'Modify bind_port in gunicorn-config.py':
      path  => '/etc/barbican/gunicorn-config.py',
      line  => "bind = '${bind_host}:${bind_port}'",
      match => '.*bind = .*',
      tag   => 'modify-bind-port',
    }

  } elsif $service_name == 'httpd' {
    include ::apache::params
    # Ubuntu packages does not have a barbican-api service
    if $::os_package_type != 'ubuntu' {
      service { 'barbican-api':
        ensure => 'stopped',
        name   => $::barbican::params::api_service_name,
        enable => false,
        tag    => 'barbican-service',
      }
      Service <| title == 'httpd' |> { tag +> 'barbican-service' }

      # we need to make sure barbican-api is stopped before trying to start apache
      Service['barbican-api'] -> Service[$service_name]
    }
  } else {
    fail('Invalid service_name. Use barbican-api for stand-alone or httpd')
  }

  oslo::middleware { 'barbican_config':
    enable_proxy_headers_parsing => $enable_proxy_headers_parsing,
    max_request_body_size        => $max_request_body_size,
  }

}
