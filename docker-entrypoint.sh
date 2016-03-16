#!/bin/bash
set -e

# allow the container to be started with `--user`
if [ "$1" = 'rabbitmq-server' -a "$(id -u)" = '0' ]; then
	chown -R rabbitmq /var/lib/rabbitmq
fi

# Always run as the RabbitMQ user: Greatly simplifies permissions handling
if [ "$(id -u)" = '0' ]; then
    exec gosu rabbitmq "$BASH_SOURCE" "$@"
fi

ssl=
if [ "$RABBITMQ_SSL_CERT_FILE" -a "$RABBITMQ_SSL_KEY_FILE" -a "$RABBITMQ_SSL_CA_FILE" ]; then
	ssl=1
fi

# If long & short hostnames are not the same, use long hostnames
if [ "$(hostname)" != "$(hostname -s)" ]; then
	export RABBITMQ_USE_LONGNAME=true
fi

if [ "$RABBITMQ_ERLANG_COOKIE" ]; then
	cookieFile='/var/lib/rabbitmq/.erlang.cookie'
	if [ -e "$cookieFile" ]; then
		if [ "$(cat "$cookieFile" 2>/dev/null)" != "$RABBITMQ_ERLANG_COOKIE" ]; then
			echo >&2
			echo >&2 "warning: $cookieFile contents do not match RABBITMQ_ERLANG_COOKIE"
			echo >&2
		fi
	else
		echo "$RABBITMQ_ERLANG_COOKIE" > "$cookieFile"
		chmod 600 "$cookieFile"
	fi
fi

if [ "$1" = 'rabbitmq-server' ]; then
	configs=(
		# https://www.rabbitmq.com/configure.html
		default_pass
		default_user
		default_vhost
		ssl_ca_file
		ssl_cert_file
		ssl_key_file
		set_vm_memory_high_watermark
		vm_memory_high_watermark_paging_ratio
		disk_free_limit
		tcp_listen_options
		kernel
		cluster_partition_handling
	)

	haveConfig=
	for conf in "${configs[@]}"; do
		var="RABBITMQ_${conf^^}"
		val="${!var}"
		if [ "$val" ]; then
			haveConfig=1
			break
		fi
	done

	if [ "$haveConfig" ]; then
		cat > /etc/rabbitmq/rabbitmq.config <<-'EOH'
			[
			  {rabbit,
			    [
		EOH
		
		if [ "$ssl" ]; then
			if [ -z "$RABBITMQ_SSL_VERIFY" ]; then
			    RABBITMQ_SSL_VERIFY='verify_peer'
			fi
			if [ -z "$RABBITMQ_FAIL_IF_NO_PEER_CERT" ]; then
			   RABBITMQ_FAIL_IF_NO_PEER_CERT='true'
			fi
			cat >> /etc/rabbitmq/rabbitmq.config <<-EOS
			      { tcp_listeners, [ ] },
			      { ssl_listeners, [ 5671 ] },
			      { ssl_options,  [
			        { certfile,   "$RABBITMQ_SSL_CERT_FILE" },
			        { keyfile,    "$RABBITMQ_SSL_KEY_FILE" },
			        { cacertfile, "$RABBITMQ_SSL_CA_FILE" },
			        { verify,   $RABBITMQ_SSL_VERIFY },
			        { fail_if_no_peer_cert, $RABBITMQ_FAIL_IF_NO_PEER_CERT } ] },
			EOS
		else
			cat >> /etc/rabbitmq/rabbitmq.config <<-EOS
			      { tcp_listeners, [ 5672 ] },
			      { ssl_listeners, [ ] },
			EOS
		fi
		
		for conf in "${configs[@]}"; do
			[ "${conf#ssl_}" = "$conf" ] || continue
			var="RABBITMQ_${conf^^}"
			val="${!var}"
			[ "$val" ] || continue
			if [ "${conf#default_}" = "$conf" ]; then
				# Pass argument directly as it's formatting is unknown
				cat >> /etc/rabbitmq/rabbitmq.config <<-EOC
				      {$conf, $val},
				EOC
			else
				cat >> /etc/rabbitmq/rabbitmq.config <<-EOC
				      {$conf, <<"$val">>},
				EOC
			fi
		done
		cat >> /etc/rabbitmq/rabbitmq.config <<-'EOF'
			      {loopback_users, []}
		EOF

		# If management plugin is installed, then generate config consider this
		if [ "$(rabbitmq-plugins list -m -e rabbitmq_management)" ]; then
			cat >> /etc/rabbitmq/rabbitmq.config <<-'EOF'
				    ]
				  },
				  { rabbitmq_management, [
				      { listener, [
			EOF

			if [ "$ssl" ]; then
				cat >> /etc/rabbitmq/rabbitmq.config <<-EOS
				        { port, 15671 },
				        { ssl, true },
				        { ssl_opts, [
				          { certfile,   "$RABBITMQ_SSL_CERT_FILE" },
				          { keyfile,    "$RABBITMQ_SSL_KEY_FILE" },
				          { cacertfile, "$RABBITMQ_SSL_CA_FILE" },
				          { verify,   verify_none },
				          { fail_if_no_peer_cert, false }
				          ]
				        }
				EOS
			else
				cat >> /etc/rabbitmq/rabbitmq.config <<-EOS
				        { port, 15672 },
				        { ssl, false }
				EOS
			fi
			cat >> /etc/rabbitmq/rabbitmq.config <<-EOS
			        ]
			      }
			EOS

		fi

		cat >> /etc/rabbitmq/rabbitmq.config <<-'EOF'
			    ]
			  }
			].
		EOF
	fi
fi

if [ "$ssl" ]; then
	# Create combined cert
	combined_file="/tmp/combined.pem"
	cat "$RABBITMQ_SSL_CERT_FILE" "$RABBITMQ_SSL_KEY_FILE" > $combined_file
	chmod 0600 $combined_file

	# More ENV vars for make clustering happiness
	# we don't handle clustering in this script, but these args should ensure
	# clustered SSL-enabled members will talk nicely
	export ERL_SSL_PATH="$(erl -eval 'io:format("~p", [code:lib_dir(ssl, ebin)]),halt().' -noshell)"
	export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-pa '$ERL_SSL_PATH' -proto_dist inet_tls -ssl_dist_opt server_certfile $combined_file -ssl_dist_opt server_secure_renegotiate true client_secure_renegotiate true"
	export RABBITMQ_CTL_ERL_ARGS="$RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS"
fi

exec "$@"
