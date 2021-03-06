#!/bin/sh
# Copyright (C) 2018-2020 Lienol <lawlienol@gmail.com>

. $IPKG_INSTROOT/lib/functions.sh
. $IPKG_INSTROOT/lib/functions/service.sh

CONFIG=passwall
TMP_PATH=/var/etc/$CONFIG
TMP_BIN_PATH=$TMP_PATH/bin
TMP_ID_PATH=$TMP_PATH/id
TMP_PORT_PATH=$TMP_PATH/port
LOG_FILE=/var/log/$CONFIG.log
APP_PATH=/usr/share/$CONFIG
RULES_PATH=/usr/share/${CONFIG}/rules
TMP_DNSMASQ_PATH=/var/etc/dnsmasq-passwall.d
DNSMASQ_PATH=/etc/dnsmasq.d
RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
DNS_PORT=7913
LUA_API_PATH=/usr/lib/lua/luci/model/cbi/$CONFIG/api
API_GEN_SS=$LUA_API_PATH/gen_shadowsocks.lua
API_GEN_V2RAY=$LUA_API_PATH/gen_v2ray.lua
API_GEN_TROJAN=$LUA_API_PATH/gen_trojan.lua
echolog() {
	local d="$(date "+%Y-%m-%d %H:%M:%S")"
	echo -e "$d: $1" >>$LOG_FILE
}

find_bin() {
	bin_name=$1
	result=$(find /usr/*bin -iname "$bin_name" -type f)
	if [ -z "$result" ]; then
		echo "null"
	else
		echo "$result"
	fi
}

config_n_get() {
	local ret=$(uci -q get $CONFIG.$1.$2 2>/dev/null)
	echo ${ret:=$3}
}

config_t_get() {
	local index=0
	[ -n "$4" ] && index=$4
	local ret=$(uci -q get $CONFIG.@$1[$index].$2 2>/dev/null)
	echo ${ret:=$3}
}

get_host_ip() {
	local host=$2
	local count=$3
	[ -z "$count" ] && count=3
	local isip=""
	local ip=$host
	if [ "$1" == "ipv6" ]; then
		isip=$(echo $host | grep -E "([[a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7}])")
		if [ -n "$isip" ]; then
			isip=$(echo $host | cut -d '[' -f2 | cut -d ']' -f1)
		else
			isip=$(echo $host | grep -E "([a-f0-9]{1,4}(:[a-f0-9]{1,4}){7}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){0,7}::[a-f0-9]{0,4}(:[a-f0-9]{1,4}){0,7})")
		fi
	else
		isip=$(echo $host | grep -E "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
	fi
	[ -z "$isip" ] && {
		local t=4
		[ "$1" == "ipv6" ] && t=6
		local vpsrip=$(resolveip -$t -t $count $host | awk 'NR==1{print}')
		ip=$vpsrip
	}
	echo $ip
}

get_node_host_ip() {
	local ip
	local address=$(config_n_get $1 address)
	[ -n "$address" ] && {
		local use_ipv6=$(config_n_get $1 use_ipv6)
		local network_type="ipv4"
		[ "$use_ipv6" == "1" ] && network_type="ipv6"
		ip=$(get_host_ip $network_type $address)
	}
	echo $ip
}

hosts_foreach() {
	local __hosts
	eval "__hosts=\$${1}"; shift 1
	local __func=${1}; shift 1
	local __default_port=${1}; shift 1
	local __ret=1

	[ -z "${__hosts}" ] && return 0
	local __ip __port
	for __host in $(echo $__hosts | sed 's/[ ,]/\n/g'); do
		__ip=$(echo $__host | sed -n 's/\(^[^:#]*\).*$/\1/p')
		[ -n "${__default_port}" ] && __port=$(echo $__host | sed -n 's/^[^:#]*[:#]\([0-9]*\).*$/\1/p')
		eval "$__func \"${__host}\" \"\${__ip}\" \"\${__port:-${__default_port}}\" $@"
		__ret=$?
		[ ${__ret} -ge ${ERROR_NO_CATCH:-1} ] && return ${__ret}
	done
}

get_first_dns() {
	local __hosts_val=${1}; shift 1
	__first() {
		[ -z "${2}" ] && return 0
		echo "${2}#${3}"
		return 1
	}
	eval "hosts_foreach \"${__hosts_val}\" __first $@"
}

get_last_dns() {
	local __hosts_val=${1}; shift 1
	local __first __last
	__every() {
		[ -z "${2}" ] && return 0
		__last="${2}#${3}"
		__first=${__first:-${__last}}
	}
	eval "hosts_foreach \"${__hosts_val}\" __every $@"
	[ "${__first}" ==  "${__last}" ] || echo "${__last}"
}

check_port_exists() {
	port=$1
	protocol=$2
	result=
	if [ "$protocol" = "tcp" ]; then
		result=$(netstat -tln | grep -c ":$port ")
	elif [ "$protocol" = "udp" ]; then
		result=$(netstat -uln | grep -c ":$port ")
	fi
	if [ "$result" = 1 ]; then
		echo 1
	else
		echo 0
	fi
}

get_new_port() {
	port=$1
	[ "$port" == "auto" ] && port=2082
	protocol=$2
	result=$(check_port_exists $port $protocol)
	if [ "$result" = 1 ]; then
		temp=
		if [ "$port" -lt 65535 ]; then
			temp=$(expr $port + 1)
		elif [ "$port" -gt 1 ]; then
			temp=$(expr $port - 1)
		fi
		get_new_port $temp $protocol
	else
		echo $port
	fi
}

ln_start_bin() {
	local file=$1
	[ "$file" != "null" ] && {
		local bin=$2
		shift 2
		if [ -n "${TMP_BIN_PATH}/$bin" -a -f "${TMP_BIN_PATH}/$bin" ];then
			${TMP_BIN_PATH}/$bin $@ >/dev/null 2>&1 &
		else
			if [ -n "$file" -a -f "$file" ];then
				ln -s $file ${TMP_BIN_PATH}/$bin
				${TMP_BIN_PATH}/$bin $@ >/dev/null 2>&1 &
			else
				echolog "?????????$bin???????????????????????????"
			fi
		fi
	}
}

ENABLED=$(config_t_get global enabled 0)

TCP_NODE_NUM=$(config_t_get global_other tcp_node_num 1)
for i in $(seq 1 $TCP_NODE_NUM); do
	eval TCP_NODE$i=$(config_t_get global tcp_node$i nil)
done
TCP_REDIR_PORT1=$(config_t_get global_forwarding tcp_redir_port 1041)
TCP_REDIR_PORT2=$(expr $TCP_REDIR_PORT1 + 1)
TCP_REDIR_PORT3=$(expr $TCP_REDIR_PORT2 + 1)

UDP_NODE_NUM=$(config_t_get global_other udp_node_num 1)
for i in $(seq 1 $UDP_NODE_NUM); do
	eval UDP_NODE$i=$(config_t_get global udp_node$i nil)
done
UDP_REDIR_PORT1=$(config_t_get global_forwarding udp_redir_port 1051)
UDP_REDIR_PORT2=$(expr $UDP_REDIR_PORT1 + 1)
UDP_REDIR_PORT3=$(expr $UDP_REDIR_PORT2 + 1)

[ "$UDP_NODE1" == "tcp_" ] && UDP_NODE1=$TCP_NODE1
[ "$UDP_NODE1" == "tcp" ] && UDP_REDIR_PORT1=$TCP_REDIR_PORT1

# Dynamic variables (Used to record)
# TCP_NODE1_IP="" UDP_NODE1_IP="" TCP_NODE1_PORT="" UDP_NODE1_PORT="" TCP_NODE1_TYPE="" UDP_NODE1_TYPE=""

TCP_REDIR_PORTS=$(config_t_get global_forwarding tcp_redir_ports '80,443')
UDP_REDIR_PORTS=$(config_t_get global_forwarding udp_redir_ports '1:65535')
TCP_NO_REDIR_PORTS=$(config_t_get global_forwarding tcp_no_redir_ports 'disable')
UDP_NO_REDIR_PORTS=$(config_t_get global_forwarding udp_no_redir_ports 'disable')
KCPTUN_REDIR_PORT=$(config_t_get global_forwarding kcptun_port 12948)
TCP_PROXY_MODE=$(config_t_get global tcp_proxy_mode chnroute)
UDP_PROXY_MODE=$(config_t_get global udp_proxy_mode chnroute)
LOCALHOST_TCP_PROXY_MODE=$(config_t_get global localhost_tcp_proxy_mode default)
LOCALHOST_UDP_PROXY_MODE=$(config_t_get global localhost_udp_proxy_mode default)
[ "$LOCALHOST_TCP_PROXY_MODE" == "default" ] && LOCALHOST_TCP_PROXY_MODE=$TCP_PROXY_MODE
[ "$LOCALHOST_UDP_PROXY_MODE" == "default" ] && LOCALHOST_UDP_PROXY_MODE=$UDP_PROXY_MODE

load_config() {
	local auto_switch_list=$(config_t_get auto_switch tcp_node1 nil)
	[ -n "$auto_switch_list" -a "$auto_switch_list" != "nil" ] && {
		for tmp in $auto_switch_list; do
			tmp_id=$(config_n_get $tmp address nil)
			[ "$tmp_id" == "nil" ] && {
				uci -q del_list $CONFIG.@auto_switch[0].tcp_node1=$tmp
				uci commit $CONFIG
			}
		done
	}
	
	[ "$ENABLED" != 1 ] && return 1
	[ "$TCP_NODE1" == "nil" -a "$UDP_NODE1" == "nil" ] && {
		echolog "?????????????????????"
		return 1
	}
	
	DNS_MODE=$(config_t_get global dns_mode pdnsd)
	DNS_FORWARD=$(config_t_get global dns_forward 8.8.4.4:53)
	DNS_CACHE=$(config_t_get global dns_cache 1)
	use_tcp_node_resolve_dns=0
	use_udp_node_resolve_dns=0
	process=1
	if [ "$(config_t_get global_forwarding process 0)" = "0" ]; then
		process=$(cat /proc/cpuinfo | grep 'processor' | wc -l)
	else
		process=$(config_t_get global_forwarding process)
	fi
	UP_CHINA_DNS=$(config_t_get global up_china_dns dnsbyisp)
	[ "$UP_CHINA_DNS" == "default" ] && IS_DEFAULT_CHINA_DNS=1
	[ ! -f "$RESOLVFILE" -o ! -s "$RESOLVFILE" ] && RESOLVFILE=/tmp/resolv.conf.auto
	if [ "$UP_CHINA_DNS" == "dnsbyisp" -o "$UP_CHINA_DNS" == "default" ]; then
		UP_CHINA_DNS1=$(cat $RESOLVFILE 2>/dev/null | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n '1P')
		DEFAULT_DNS1="$UP_CHINA_DNS1"
		[ -z "$UP_CHINA_DNS1" ] && UP_CHINA_DNS1="119.29.29.29"
		UP_CHINA_DNS="$UP_CHINA_DNS1"
		UP_CHINA_DNS2=$(cat $RESOLVFILE 2>/dev/null | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v 0.0.0.0 | grep -v 127.0.0.1 | sed -n '2P')
		[ -n "$UP_CHINA_DNS1" -a -n "$UP_CHINA_DNS2" ] && UP_CHINA_DNS="$UP_CHINA_DNS1,$UP_CHINA_DNS2"
	else
		UP_CHINA_DNS1=$(get_first_dns UP_CHINA_DNS 53)
		if [ -n "$UP_CHINA_DNS1" ]; then
			UP_CHINA_DNS2=$(get_last_dns UP_CHINA_DNS 53)
			[ -n "$UP_CHINA_DNS2" ] && UP_CHINA_DNS="${UP_CHINA_DNS1},${UP_CHINA_DNS2}"
		else
			UP_CHINA_DNS1="119.29.29.29"
			UP_CHINA_DNS=$UP_CHINA_DNS1
		fi
	fi
	PROXY_IPV6=$(config_t_get global_forwarding proxy_ipv6 0)
	mkdir -p /var/etc $TMP_PATH $TMP_BIN_PATH $TMP_ID_PATH $TMP_PORT_PATH
	return 0
}

run_socks() {
	local node=$1
	local bind=$2
	local local_port=$3
	local config_file=$4
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	local remarks=$(config_n_get $node remarks)
	local server_host=$(config_n_get $node address)
	local port=$(config_n_get $node port)
	[ -n "$server_host" -a -n "$port" ] && {
		# ?????????????????????????????????URL?????????~
		local server_host=$(echo $server_host | sed 's/^\(https:\/\/\|http:\/\/\)//g' | awk -F '/' '{print $1}')
		# ?????????????????????????????????????????????~
		local tmp=$(echo -n $server_host | awk '{print gensub(/[!-~]/,"","g",$0)}')
		[ -n "$tmp" ] && {
			echolog "$remarks?????????????????????????????????????????????"
			return 1
		}
		[ "$bind" != "127.0.0.1" ] && echolog "Socks?????????$remarks????????????${server_host}:${port}??????????????????$local_port"
	}

	if [ "$type" == "socks" ]; then
		echolog "Socks??????????????????Socks???????????????"
	elif [ "$type" == "v2ray" ]; then
		lua $API_GEN_V2RAY $node nil nil $local_port > $config_file
		ln_start_bin $(config_t_get global_app v2ray_file $(find_bin v2ray))/v2ray v2ray "-config=$config_file"
	elif [ "$type" == "trojan" ]; then
		lua $API_GEN_TROJAN $node client $bind $local_port > $config_file
		ln_start_bin $(find_bin trojan) trojan "-c $config_file"
	elif [ "$type" == "trojan-go" ]; then
		lua $API_GEN_TROJAN $node client $bind $local_port > $config_file
		ln_start_bin $(config_t_get global_app trojan_go_file $(find_bin trojan-go)) trojan-go "-config $config_file"
	elif [ "$type" == "brook" ]; then
		local protocol=$(config_n_get $node brook_protocol client)
		local brook_tls=$(config_n_get $node brook_tls 0)
		[ "$protocol" == "wsclient" ] && {
			[ "$brook_tls" == "1" ] && server_host="wss://${server_host}" || server_host="ws://${server_host}" 
		}
		ln_start_bin $(config_t_get global_app brook_file $(find_bin brook)) brook_socks_$5 "$protocol -l $bind:$local_port -i $$bind -s $server_host:$port -p $(config_n_get $node password)"
	elif [ "$type" == "ssr" ] || [ "$type" == "ss" ]; then
		lua $API_GEN_SS $node $local_port > $config_file
		ln_start_bin $(find_bin ${type}-local) ${type}-local "-c $config_file -b $bind -u"
	fi
}

run_redir() {
	local node=$1
	local bind=$2
	local local_port=$3
	local config_file=$4
	local redir_type=$5
	local type=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
	local remarks=$(config_n_get $node remarks)
	local server_host=$(config_n_get $node address)
	local port=$(config_n_get $node port)
	[ -n "$server_host" -a -n "$port" ] && {
		# ?????????????????????????????????URL?????????~
		local server_host=$(echo $server_host | sed 's/^\(https:\/\/\|http:\/\/\)//g' | awk -F '/' '{print $1}')
		# ?????????????????????????????????????????????~
		local tmp=$(echo -n $server_host | awk '{print gensub(/[!-~]/,"","g",$0)}')
		[ -n "$tmp" ] && {
			echolog "$remarks???????????????????????????????????????????????????"
			return 1
		}
		[ "$bind" != "127.0.0.1" ] && echolog "${redir_type}_${6}?????????$remarks????????????${server_host}:${port}??????????????????$local_port"
	}
	eval ${redir_type}_NODE${6}_PORT=$port

	if [ "$redir_type" == "UDP" ]; then
		if [ "$type" == "socks" ]; then
			local node_address=$(config_n_get $node address)
			local node_port=$(config_n_get $node port)
			local server_username=$(config_n_get $node username)
			local server_password=$(config_n_get $node password)
			eval port=\$UDP_REDIR_PORT$6
			ln_start_bin $(find_bin ipt2socks) ipt2socks_udp_$6 "-U -l $port -b 0.0.0.0 -s $node_address -p $node_port -R"
		elif [ "$type" == "v2ray" ]; then
			lua $API_GEN_V2RAY $node udp $local_port nil > $config_file
			ln_start_bin $(config_t_get global_app v2ray_file $(find_bin v2ray))/v2ray v2ray "-config=$config_file"
		elif [ "$type" == "trojan" ]; then
			lua $API_GEN_TROJAN $node nat "0.0.0.0" $local_port >$config_file
			ln_start_bin $(find_bin trojan) trojan "-c $config_file"
		elif [ "$type" == "trojan-go" ]; then
			lua $API_GEN_TROJAN $node nat "0.0.0.0" $local_port >$config_file
			ln_start_bin $(config_t_get global_app trojan_go_file $(find_bin trojan-go)) trojan-go "-config $config_file"
		elif [ "$type" == "brook" ]; then
			local protocol=$(config_n_get $node brook_protocol client)
			if [ "$protocol" == "wsclient" ]; then
				echolog "Brook???WebSocket?????????UDP?????????"
			else
				ln_start_bin $(config_t_get global_app brook_file $(find_bin brook)) brook_udp_$6 "tproxy -l 0.0.0.0:$local_port -s $server_host:$port -p $(config_n_get $node password)"
			fi
		elif [ "$type" == "ssr" ] || [ "$type" == "ss" ]; then
			lua $API_GEN_SS $node $local_port > $config_file
			ln_start_bin $(find_bin ${type}-redir) ${type}-redir "-c $config_file -U"
		fi
	fi

	if [ "$redir_type" == "TCP" ]; then
		if [ "$type" == "socks" ]; then
			local node_address=$(config_n_get $node address)
			local node_port=$(config_n_get $node port)
			local server_username=$(config_n_get $node username)
			local server_password=$(config_n_get $node password)
			eval port=\$TCP_REDIR_PORT$6
			local extra_param="-T"
			[ "$6" == 1 ] && [ "$UDP_NODE1" == "tcp" ] && extra_param=""
			ln_start_bin $(find_bin ipt2socks) ipt2socks_tcp_$6 "-l $port -b 0.0.0.0 -s $node_address -p $node_port -R $extra_param"
		elif [ "$type" == "v2ray" ]; then
			local extra_param="tcp"
			[ "$6" == 1 ] && [ "$UDP_NODE1" == "tcp" ] && extra_param="tcp,udp"
			lua $API_GEN_V2RAY $node $extra_param $local_port nil > $config_file
			ln_start_bin $(config_t_get global_app v2ray_file $(find_bin v2ray))/v2ray v2ray "-config=$config_file"
		elif [ "$type" == "trojan" ]; then
			lua $API_GEN_TROJAN $node nat "0.0.0.0" $local_port > $config_file
			for k in $(seq 1 $process); do
				ln_start_bin $(find_bin trojan) trojan "-c $config_file"
			done
		elif [ "$type" == "trojan-go" ]; then
			lua $API_GEN_TROJAN $node nat "0.0.0.0" $local_port > $config_file
			ln_start_bin $(config_t_get global_app trojan_go_file $(find_bin trojan-go)) trojan-go "-config $config_file"
		else
			local kcptun_use=$(config_n_get $node use_kcp 0)
			if [ "$kcptun_use" == "1" ]; then
				local kcptun_server_host=$(config_n_get $node kcp_server)
				local network_type="ipv4"
				local kcptun_port=$(config_n_get $node kcp_port)
				local kcptun_config="$(config_n_get $node kcp_opts)"
				if [ -z "$kcptun_port" -o -z "$kcptun_config" ]; then
					echolog "Kcptun???????????????????????????"
					force_stop
				fi
				if [ -n "$kcptun_port" -a -n "$kcptun_config" ]; then
					local run_kcptun_ip=$server_host
					[ -n "$kcptun_server_host" ] && run_kcptun_ip=$(get_host_ip $network_type $kcptun_server_host)
					KCPTUN_REDIR_PORT=$(get_new_port $KCPTUN_REDIR_PORT tcp)
					ln_start_bin $(config_t_get global_app kcptun_client_file $(find_bin kcptun-client)) kcptun_tcp_$6 "-l 0.0.0.0:$KCPTUN_REDIR_PORT -r $run_kcptun_ip:$kcptun_port $kcptun_config"
				fi
			fi
			if [ "$type" == "ssr" ] || [ "$type" == "ss" ]; then
				if [ "$kcptun_use" == "1" ]; then
					lua $API_GEN_SS $node $local_port 127.0.0.1 $KCPTUN_REDIR_PORT > $config_file
					[ "$6" == 1 ] && [ "$UDP_NODE1" == "tcp" ] && echolog "Kcptun?????????UDP?????????"
				else
					lua $API_GEN_SS $node $local_port > $config_file
					[ "$6" == 1 ] && [ "$UDP_NODE1" == "tcp" ] && extra_param="-u"
				fi
				for k in $(seq 1 $process); do
					ln_start_bin $(find_bin ${type}-redir) ${type}-redir "-c $config_file $extra_param"
				done
			elif [ "$type" == "brook" ]; then
				local server_ip=$server_host
				local protocol=$(config_n_get $node brook_protocol client)
				local brook_tls=$(config_n_get $node brook_tls 0)
				if [ "$protocol" == "wsclient" ]; then
					[ "$brook_tls" == "1" ] && server_ip="wss://${server_ip}" || server_ip="ws://${server_ip}" 
					socks_port=$(get_new_port 2081 tcp)
					ln_start_bin $(config_t_get global_app brook_file $(find_bin brook)) brook_tcp_$6 "wsclient -l 127.0.0.1:$socks_port -i 127.0.0.1 -s $server_ip:$port -p $(config_n_get $node password)"
					eval port=\$TCP_REDIR_PORT$6
					ln_start_bin $(find_bin ipt2socks) ipt2socks_tcp_$6 "-T -l $port -b 0.0.0.0 -s 127.0.0.1 -p $socks_port -R"
					echolog "Brook???WebSocket?????????????????????????????????ipt2socks?????????????????????"
					[ "$6" == 1 ] && [ "$UDP_NODE1" == "tcp" ] && echolog "Brook???WebSocket?????????UDP?????????"
				else
					[ "$kcptun_use" == "1" ] && {
						server_ip=127.0.0.1
						port=$KCPTUN_REDIR_PORT
					}
					ln_start_bin $(config_t_get global_app brook_file $(find_bin brook)) brook_tcp_$6 "tproxy -l 0.0.0.0:$local_port -s $server_ip:$port -p $(config_n_get $node password)"
				fi
			fi
		fi
	fi
	return 0
}

node_switch() {
	local i=$3
	local node=$4
	[ -n "$1" -a -n "$2" -a -n "$3" -a -n "$4" ] && {
		ps -w | grep -E "$TMP_PATH" | grep -i "${1}_${i}" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
		local config_file=$TMP_PATH/${1}_${i}.json
		eval current_port=\$${1}_REDIR_PORT${i}
		local port=$(cat $TMP_PORT_PATH/${1}_${i})
		run_redir $node "0.0.0.0" $port $config_file $1 $i
		echo $node > $TMP_ID_PATH/${1}_${i}
		local node_net=$(echo $1 | tr 'A-Z' 'a-z')
		uci set $CONFIG.@global[0].${node_net}_node${i}=$node
		uci commit $CONFIG
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	}
}

start_redir() {
	eval num=\$${1}_NODE_NUM
	for i in $(seq 1 $num); do
		eval node=\$${1}_NODE$i
		[ "$node" != "nil" ] && {
			TYPE=$(echo $(config_n_get $node type) | tr 'A-Z' 'a-z')
			local config_file=$TMP_PATH/${1}_${i}.json
			eval current_port=\$${1}_REDIR_PORT$i
			local port=$(echo $(get_new_port $current_port $2))
			eval ${1}_REDIR${i}=$port
			run_redir $node "0.0.0.0" $port $config_file $1 $i
			#eval ip=\$${1}_NODE${i}_IP
			echo $node > $TMP_ID_PATH/${1}_${i}
			echo $port > $TMP_PORT_PATH/${1}_${i}
		}
	done
}

start_socks() {
	local ids=$(uci show $CONFIG | grep "=socks" | awk -F '.' '{print $2}' | awk -F '=' '{print $1}')
	for id in $ids; do
		local enabled=$(config_n_get $id enabled 0)
		[ "$enabled" == "0" ] && continue
		local node=$(config_n_get $id node nil)
		if [ "$(echo $node | grep ^tcp)" ]; then
			local num=$(echo $node | sed "s/tcp//g")
			eval node=\$TCP_NODE$num
		fi
		[ "$node" == "nil" ] && continue
		local config_file=$TMP_PATH/SOCKS_${id}.json
		local port=$(config_n_get $id port)
		run_socks $node "0.0.0.0" $port $config_file $id
	done
}

clean_log() {
	logsnum=$(cat $LOG_FILE 2>/dev/null | wc -l)
	[ "$logsnum" -gt 300 ] && {
		echo "" > $LOG_FILE
		echolog "????????????????????????????????????"
	}
}

start_crontab() {
	touch /etc/crontabs/root
	sed -i "/$CONFIG/d" /etc/crontabs/root >/dev/null 2>&1 &
	auto_on=$(config_t_get global_delay auto_on 0)
	if [ "$auto_on" = "1" ]; then
		time_off=$(config_t_get global_delay time_off)
		time_on=$(config_t_get global_delay time_on)
		time_restart=$(config_t_get global_delay time_restart)
		[ -z "$time_off" -o "$time_off" != "nil" ] && {
			echo "0 $time_off * * * /etc/init.d/$CONFIG stop" >>/etc/crontabs/root
			echolog "??????????????????????????? $time_off ??????????????????"
		}
		[ -z "$time_on" -o "$time_on" != "nil" ] && {
			echo "0 $time_on * * * /etc/init.d/$CONFIG start" >>/etc/crontabs/root
			echolog "??????????????????????????? $time_on ??????????????????"
		}
		[ -z "$time_restart" -o "$time_restart" != "nil" ] && {
			echo "0 $time_restart * * * /etc/init.d/$CONFIG restart" >>/etc/crontabs/root
			echolog "??????????????????????????? $time_restart ??????????????????"
		}
	fi

	autoupdate=$(config_t_get global_rules auto_update)
	weekupdate=$(config_t_get global_rules week_update)
	dayupdate=$(config_t_get global_rules time_update)
	if [ "$autoupdate" = "1" ]; then
		local t="0 $dayupdate * * $weekupdate"
		[ "$weekupdate" = "7" ] && t="0 $dayupdate * * *"
		echo "$t lua $APP_PATH/rule_update.lua nil log > /dev/null 2>&1 &" >>/etc/crontabs/root
		echolog "??????????????????????????????????????????"
	fi

	autoupdatesubscribe=$(config_t_get global_subscribe auto_update_subscribe)
	weekupdatesubscribe=$(config_t_get global_subscribe week_update_subscribe)
	dayupdatesubscribe=$(config_t_get global_subscribe time_update_subscribe)
	if [ "$autoupdatesubscribe" = "1" ]; then
		local t="0 $dayupdatesubscribe * * $weekupdatesubscribe"
		[ "$weekupdatesubscribe" = "7" ] && t="0 $dayupdatesubscribe * * *"
		echo "$t lua $APP_PATH/subscribe.lua start log > /dev/null 2>&1 &" >>/etc/crontabs/root
		echolog "????????????????????????????????????????????????"
	fi
	
	start_daemon=$(config_t_get global_delay start_daemon 0)
	[ "$start_daemon" = "1" ] && $APP_PATH/monitor.sh > /dev/null 2>&1 &
	
	AUTO_SWITCH_ENABLE=$(config_t_get auto_switch enable 0)
	[ "$AUTO_SWITCH_ENABLE" = "1" ] && $APP_PATH/test.sh > /dev/null 2>&1 &
	
	/etc/init.d/cron restart
}

stop_crontab() {
	touch /etc/crontabs/root
	sed -i "/$CONFIG/d" /etc/crontabs/root >/dev/null 2>&1 &
	ps | grep "$APP_PATH/test.sh" | grep -v "grep" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	/etc/init.d/cron restart
	#echolog "???????????????????????????"
}

start_dns() {
	DNS2SOCKS_SOCKS_SERVER=$(echo $(config_t_get global socks_server nil) | sed "s/#/:/g")
	DNS2SOCKS_FORWARD=$(get_first_dns DNS_FORWARD 53 | sed 's/#/:/g')
	case "$DNS_MODE" in
	nonuse)
		echolog "DNS???????????????????????????????????????DNS???"
	;;
	local_7913)
		echolog "DNS???????????????7913??????DNS?????????????????????..."
	;;
	dns2socks)
		[ "$DNS2SOCKS_SOCKS_SERVER" != "nil" ] && {
			[ "$DNS_CACHE" == "0" ] && local _cache="/d"
			ln_start_bin $(find_bin dns2socks) dns2socks "$DNS2SOCKS_SOCKS_SERVER $DNS2SOCKS_FORWARD 127.0.0.1:$DNS_PORT $_cache"
			echolog "DNS???dns2socks(${DNS2SOCKS_FORWARD-D46.182.19.48:53})..."
		}
	;;
	pdnsd)
		if [ -z "$TCP_NODE1" -o "$TCP_NODE1" == "nil" ]; then
			echolog "DNS???pdnsd ??????????????????TCP?????????"
			force_stop
		else
			gen_pdnsd_config $DNS_PORT
			ln_start_bin $(find_bin pdnsd) pdnsd "--daemon -c $pdnsd_dir/pdnsd.conf -d"
			echolog "DNS???pdnsd + ??????TCP????????????DNS..."
		fi
	;;
	chinadns-ng)
		local china_ng_chn=$(echo $UP_CHINA_DNS | sed 's/:/#/g')
		local china_ng_gfw=$(echo $DNS_FORWARD | sed 's/:/#/g')
		other_port=$(expr $DNS_PORT + 1)
		[ -f "$RULES_PATH/gfwlist.conf" ] && cat $RULES_PATH/gfwlist.conf | sort | uniq | sed -e '/127.0.0.1/d' | sed 's/ipset=\/.//g' | sed 's/\/gfwlist//g' > $TMP_PATH/gfwlist.txt
		[ -f "$TMP_PATH/gfwlist.txt" ] && {
			[ -f "$RULES_PATH/blacklist_host" -a -s "$RULES_PATH/blacklist_host" ] && cat $RULES_PATH/blacklist_host >> $TMP_PATH/gfwlist.txt
			local gfwlist_param="-g $TMP_PATH/gfwlist.txt"
		}
		[ -f "$RULES_PATH/chnlist" ] && cp -a $RULES_PATH/chnlist $TMP_PATH/chnlist
		[ -f "$TMP_PATH/chnlist" ] && {
			[ -f "$RULES_PATH/whitelist_host" -a -s "$RULES_PATH/whitelist_host" ] && cat $RULES_PATH/whitelist_host >> $TMP_PATH/chnlist
			local chnlist_param="-m $TMP_PATH/chnlist -M"
		}
		
		local fair_mode=$(config_t_get global fair_mode 1)
		if [ "$fair_mode" == "1" ]; then
			fair_mode="-f"
		else
			fair_mode=""
		fi
		
		up_trust_chinadns_ng_dns=$(config_t_get global up_trust_chinadns_ng_dns "pdnsd")
		if [ "$up_trust_chinadns_ng_dns" == "pdnsd" ]; then
			if [ -z "$TCP_NODE1" -o "$TCP_NODE1" == "nil" ]; then
				echolog "DNS???ChinaDNS-NG + pdnsd ??????????????????TCP?????????"
				force_stop
			else
				gen_pdnsd_config $other_port
				ln_start_bin $(find_bin pdnsd) pdnsd "--daemon -c $pdnsd_dir/pdnsd.conf -d"
				ln_start_bin $(find_bin chinadns-ng) chinadns-ng "-l $DNS_PORT -c $china_ng_chn -t 127.0.0.1#$other_port $gfwlist_param $chnlist_param $fair_mode"
				echolog "DNS???ChinaDNS-NG + pdnsd($china_ng_gfw)?????????DNS???$china_ng_chn"
			fi
		elif [ "$up_trust_chinadns_ng_dns" == "dns2socks" ]; then
			[ "$DNS2SOCKS_SOCKS_SERVER" != "nil" ] && {
				[ "$DNS_CACHE" == "0" ] && local _cache="/d"
				ln_start_bin $(find_bin dns2socks) dns2socks "$DNS2SOCKS_SOCKS_SERVER $DNS2SOCKS_FORWARD 127.0.0.1:$other_port $_cache"
				ln_start_bin $(find_bin chinadns-ng) chinadns-ng "-l $DNS_PORT -c $china_ng_chn -t 127.0.0.1#$other_port $gfwlist_param $chnlist_param $fair_mode"
				echolog "DNS???ChinaDNS-NG + dns2socks(${DNS2SOCKS_FORWARD:-D46.182.19.48:53})?????????DNS???$china_ng_chn"
			}
		elif [ "$up_trust_chinadns_ng_dns" == "udp" ]; then
			use_udp_node_resolve_dns=1
			ln_start_bin $(find_bin chinadns-ng) chinadns-ng "-l $DNS_PORT -c $china_ng_chn -t $china_ng_gfw $gfwlist_param $chnlist_param $fair_mode"
			echolog "DNS???ChinaDNS-NG?????????DNS???$china_ng_chn?????????DNS???$up_trust_chinadns_ng_dns[$china_ng_gfw]?????????????????????????????????UDP???????????????????????????UDP?????????"
		fi
	;;
	esac
}

add_dnsmasq() {
	mkdir -p $TMP_DNSMASQ_PATH $DNSMASQ_PATH /var/dnsmasq.d
	local adblock=$(config_t_get global_rules adblock 0)
	local chinadns_mode=0
	[ "$DNS_MODE" == "chinadns-ng" ] && [ "$IS_DEFAULT_CHINA_DNS" != 1 ] && chinadns_mode=1
	[ "$adblock" == "1" ] && {
		[ -f "$RULES_PATH/adblock.conf" -a -s "$RULES_PATH/adblock.conf" ] && ln -s $RULES_PATH/adblock.conf $TMP_DNSMASQ_PATH/adblock.conf
	}
	
	[ "$DNS_MODE" != "nonuse" ] && {
		[ -f "$RULES_PATH/whitelist_host" -a -s "$RULES_PATH/whitelist_host" ] && cat $RULES_PATH/whitelist_host | sed -e "/^$/d" | sort -u | awk '{if (mode == 0 && dns1 != "") print "server=/."$1"/'$UP_CHINA_DNS1'"; if (mode == 0 && dns2 != "") print "server=/."$1"/'$UP_CHINA_DNS2'"; print "ipset=/."$1"/whitelist"}' mode=$chinadns_mode dns1=$UP_CHINA_DNS1 dns2=$UP_CHINA_DNS2 > $TMP_DNSMASQ_PATH/whitelist_host.conf
		uci show $CONFIG | grep ".address=" | cut -d "'" -f 2 | sed 's/^\(https:\/\/\|http:\/\/\)//g' | awk -F '/' '{print $1}' | grep -v "google.c" | grep -E '.*\..*$' | grep '[a-zA-Z]$' | sort -u | awk '{if (dns1 != "") print "server=/."$1"/'$UP_CHINA_DNS1'"; if (dns2 != "") print "server=/."$1"/'$UP_CHINA_DNS2'"; print "ipset=/."$1"/vpsiplist"}' dns1=$UP_CHINA_DNS1 dns2=$UP_CHINA_DNS2 > $TMP_DNSMASQ_PATH/vpsiplist_host.conf
		[ -f "$RULES_PATH/blacklist_host" -a -s "$RULES_PATH/blacklist_host" ] && cat $RULES_PATH/blacklist_host | sed -e "/^$/d" | sort -u | awk '{if (mode == 0) print "server=/."$1"/127.0.0.1#'$DNS_PORT'"; print "ipset=/."$1"/blacklist"}' mode=$chinadns_mode > $TMP_DNSMASQ_PATH/blacklist_host.conf
		if [ "$chinadns_mode" == 0 ]; then
			[ -f "$RULES_PATH/gfwlist.conf" -a -s "$RULES_PATH/gfwlist.conf" ] && ln -s $RULES_PATH/gfwlist.conf $TMP_DNSMASQ_PATH/gfwlist.conf
		else
			cat $TMP_PATH/gfwlist.txt | sed -e "/^$/d" | sort -u | awk '{print "ipset=/."$1"/gfwlist"}' > $TMP_DNSMASQ_PATH/gfwlist.conf
		fi
		
		subscribe_proxy=$(config_t_get global_subscribe subscribe_proxy 0)
		[ "$subscribe_proxy" -eq 1 ] && {
			local count=$(uci show $CONFIG | grep "@subscribe_list" | sed -n '$p' | cut -d '[' -f 2 | cut -d ']' -f 1)
			[ -n "$count" ] && [ "$count" -ge 0 ] && {
				u_get() {
					local ret=$(uci -q get $CONFIG.@subscribe_list[$1].$2)
					echo ${ret:=$3}
				}
				for i in $(seq 0 $count); do
					local enabled=$(u_get $i enabled 0)
					[ "$enabled" == "0" ] && continue
					local url=$(u_get $i url)
					[ -n "$url" -a "$url" != "" ] && {
						if [ -n "$(echo -n "$url" | grep "//")" ]; then
							[ "$chinadns_mode" == 0 ] && echo -n "$url" | awk -F '/' '{print $3}' | sed "s/^/server=&\/./g" | sed "s/$/\/127.0.0.1#$DNS_PORT/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
							echo -n "$url" | awk -F '/' '{print $3}' | sed "s/^/ipset=&\/./g" | sed "s/$/\/blacklist/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
						else
							[ "$chinadns_mode" == 0 ] && echo -n "$url" | awk -F '/' '{print $1}' | sed "s/^/server=&\/./g" | sed "s/$/\/127.0.0.1#$DNS_PORT/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
							echo -n "$url" | awk -F '/' '{print $1}' | sed "s/^/ipset=&\/./g" | sed "s/$/\/blacklist/g" >>$TMP_DNSMASQ_PATH/subscribe.conf
						fi
					}
				done
			}
		}
	}
	
	if [ -z "$IS_DEFAULT_CHINA_DNS" -o "$IS_DEFAULT_CHINA_DNS" == 0 ]; then
		server="server=127.0.0.1#$DNS_PORT"
		[ "$DNS_MODE" != "chinadns-ng" ] && {
			[ -n "$UP_CHINA_DNS1" ] && server="server=$UP_CHINA_DNS1"
			[ -n "$UP_CHINA_DNS2" ] && server="${server}\nserver=${UP_CHINA_DNS2}"
		}
		cat <<-EOF > /var/dnsmasq.d/dnsmasq-$CONFIG.conf
			$(echo -e $server)
			all-servers
			no-poll
			no-resolv
		EOF
	else
		[ -z "$DEFAULT_DNS1" ] && {
			local tmp=$(get_host_ip ipv4 www.baidu.com 1)
			[ -z "$tmp" ] && {
				cat <<-EOF > /var/dnsmasq.d/dnsmasq-$CONFIG.conf
					server=$UP_CHINA_DNS1
					no-poll
					no-resolv
				EOF
				echolog "?????????????????????DNS?????????????????????"
				/etc/init.d/dnsmasq restart >/dev/null 2>&1
			}
		}
	fi
	
	echo "conf-dir=$TMP_DNSMASQ_PATH" >> /var/dnsmasq.d/dnsmasq-$CONFIG.conf
	cp -rf /var/dnsmasq.d/dnsmasq-$CONFIG.conf $DNSMASQ_PATH/dnsmasq-$CONFIG.conf
	echolog "dnsmasq????????????????????????"
}

gen_pdnsd_config() {
	pdnsd_dir=$TMP_PATH/pdnsd
	mkdir -p $pdnsd_dir
	touch $pdnsd_dir/pdnsd.cache
	chown -R root.nogroup $pdnsd_dir
	local perm_cache=2048
	local _cache="on"
	[ "$DNS_CACHE" == "0" ] && _cache="off" && perm_cache=0
	cat > $pdnsd_dir/pdnsd.conf <<-EOF
		global {
			perm_cache = $perm_cache;
			cache_dir = "$pdnsd_dir";
			run_as = "root";
			server_ip = 127.0.0.1;
			server_port = $1;
			status_ctl = on;
			query_method = tcp_only;
			min_ttl = 1h;
			max_ttl = 1w;
			timeout = 10;
			par_queries = 1;
			neg_domain_pol = on;
			udpbufsize = 1024;
			proc_limit = 2;
			procq_limit = 8;
		}
		
	EOF

	append_pdnsd_updns() {
		[ -z "${2}" ] && echolog "????????????????????? DNS : [${1}]" && return 0
		echolog "?????? pdnsd ?????????DNS[${2}:${3}]"
		cat >> $pdnsd_dir/pdnsd.conf <<-EOF
			server {
				label = "node-${2}_${3}";
				ip = ${1};
				edns_query = on;
				port = ${3};
				timeout = 4;
				interval = 10m;
				uptest = none;
				purge_cache = off;
				caching = $_cache;
			}
		EOF
	}
	hosts_foreach DNS_FORWARD append_pdnsd_updns 53

	use_tcp_node_resolve_dns=1
}

del_dnsmasq() {
	rm -rf /var/dnsmasq.d/dnsmasq-$CONFIG.conf
	rm -rf $DNSMASQ_PATH/dnsmasq-$CONFIG.conf
	rm -rf $TMP_DNSMASQ_PATH
}

start_haproxy() {
	enabled=$(config_t_get global_haproxy balancing_enable 0)
	[ "$enabled" = "1" ] && {
		haproxy_bin=$(find_bin haproxy)
		[ -f "$haproxy_bin" ] && {
			local HAPROXY_PATH=$TMP_PATH/haproxy
			mkdir -p $HAPROXY_PATH
			local HAPROXY_FILE=$HAPROXY_PATH/config.cfg
			bport=$(config_t_get global_haproxy haproxy_port)
			cat <<-EOF > $HAPROXY_FILE
				global
				    log         127.0.0.1 local2
				    chroot      /usr/bin
				    maxconn     60000
				    stats socket  $HAPROXY_PATH/haproxy.sock
				    user        root
				    daemon
					
				defaults
				    mode                    tcp
				    log                     global
				    option                  tcplog
				    option                  dontlognull
				    option http-server-close
				    #option forwardfor       except 127.0.0.0/8
				    option                  redispatch
				    retries                 2
				    timeout http-request    10s
				    timeout queue           1m
				    timeout connect         10s
				    timeout client          1m
				    timeout server          1m
				    timeout http-keep-alive 10s
				    timeout check           10s
				    maxconn                 3000
					
			EOF
			
			local ports=$(uci show $CONFIG | grep "@haproxy_config" | grep haproxy_port | cut -d "'" -f 2 | sort -u)
			for p in $ports; do
				cat <<-EOF >> $HAPROXY_FILE
					listen $p
					    mode tcp
					    bind 0.0.0.0:$p
						
				EOF
			done
			
			local count=$(uci show $CONFIG | grep "@haproxy_config" | sed -n '$p' | cut -d '[' -f 2 | cut -d ']' -f 1)
			[ -n "$count" ] && [ "$count" -ge 0 ] && {
				u_get() {
					local ret=$(uci -q get $CONFIG.@haproxy_config[$1].$2)
					echo ${ret:=$3}
				}
				for i in $(seq 0 $count); do
					local enabled=$(u_get $i enabled 0)
					[ -z "$enabled" -o "$enabled" == "0" ] && continue
					
					local haproxy_port=$(u_get $i haproxy_port)
					[ -z "$haproxy_port" ] && continue
					
					local bips=$(u_get $i lbss)
					local bports=$(u_get $i lbort)
					if [ -z "$bips" ] || [ -z "$bports" ]; then
						continue
					fi
					
					local bip=$(echo $bips | awk -F ":" '{print $1}')
					local bport=$(echo $bips | awk -F ":" '{print $2}')
					[ "$bports" != "default" ] && bport=$bports
					[ -z "$bport" ] && continue
					
					local line=$(cat $HAPROXY_FILE | grep -n "bind 0.0.0.0:$haproxy_port" | awk -F ":" '{print $1}')
					[ -z "$line" ] && continue
					
					local bweight=$(u_get $i lbweight)
					local exports=$(u_get $i export)
					local backup=$(u_get $i backup)
					local bbackup=""
					[ "$backup" = "1" ] && bbackup="backup"
					sed -i "${line}i \ \ \ \ server $bip:$bport $bip:$bport weight $bweight check inter 1500 rise 1 fall 3 $bbackup" $HAPROXY_FILE
					if [ "$exports" != "0" ]; then
						failcount=0
						while [ "$failcount" -lt "3" ]; do
							interface=$(ifconfig | grep "$exports" | awk '{print $1}')
							if [ -z "$interface" ]; then
								echolog "????????????????????????$exports???1??????????????????"
								let "failcount++"
								[ "$failcount" -ge 3 ] && exit 0
								sleep 1m
							else
								route add -host ${bip} dev ${exports}
								echo "$bip" >>/tmp/balancing_ip
								break
							fi
						done
					fi
				done
			}
			
			# ???????????????
			local console_port=$(config_t_get global_haproxy console_port)
			local console_user=$(config_t_get global_haproxy console_user)
			local console_password=$(config_t_get global_haproxy console_password)
			local auth=""
			[ -n "$console_user" -a -n "console_password" ] && auth="stats auth $console_user:$console_password"
			cat <<-EOF >> $HAPROXY_FILE
				listen console
				    bind 0.0.0.0:$console_port
				    mode http                   
				    stats refresh 30s
				    stats uri /
				    stats admin if TRUE
				    $auth
			EOF
			
			ln_start_bin $haproxy_bin haproxy "-f $HAPROXY_FILE"
		}
	}
}

kill_all() {
	kill -9 $(pidof $@) >/dev/null 2>&1 &
}

force_stop() {
	stop
	exit 0
}

boot() {
	[ "$ENABLED" == 1 ] && {
		local delay=$(config_t_get global_delay start_delay 1)
		if [ "$delay" -gt 0 ]; then
			echolog "?????????????????? $delay ???????????????!"
			sleep $delay && start >/dev/null 2>&1 &
		else
			start
		fi
	}
	return 0
}

start() {
	! load_config && return 1
	start_haproxy
	start_socks
	start_redir TCP tcp
	start_redir UDP udp
	start_dns
	add_dnsmasq
	source $APP_PATH/iptables.sh start
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	start_crontab
	echolog "???????????????\n"
}

stop() {
	clean_log
	source $APP_PATH/iptables.sh stop
	kill_all v2ray-plugin obfs-local
	ps -w | grep -v "grep" | grep $CONFIG/test.sh | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	ps -w | grep -v "grep" | grep $CONFIG/monitor.sh | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	ps -w | grep -v -E "grep|${TMP_PATH}_server" | grep -E "$TMP_PATH" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	ps -w | grep -v "grep" | grep "sleep 1m" | awk '{print $1}' | xargs kill -9 >/dev/null 2>&1 &
	rm -rf $TMP_DNSMASQ_PATH $TMP_PATH
	stop_crontab
	del_dnsmasq
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	echolog "?????????????????????????????????????????????"
}

case $1 in
get_new_port)
	get_new_port $2 $3
	;;
run_socks)
	run_socks $2 $3 $4 $5 $6
	;;
run_redir)
	run_redir $2 $3 $4 $5 $6 $7
	;;
node_switch)
	node_switch $2 $3 $4 $5
	;;
stop)
	[ -n "$2" -a "$2" == "force" ] && force_stop
	stop
	;;
start)
	start
	;;
boot)
	boot
	;;
esac
