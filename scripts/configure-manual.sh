#!/bin/bash
# This program automates common/essential tasks for building catapult-server

prog=$0
jobs=4
if [[ -f /proc/cpuinfo ]]; then
	jobs=`cat /proc/cpuinfo | grep "^processor" | wc -l`
fi
depsdir=""
hostaddr=`hostname -I | awk '{print $1'}`
warn_env=0
depsdir=$CAT_DEPS_DIR
if [ "_$CAT_DEPS_DIR" == "_" ]; then
	CAT_DEPS_DIR="$HOME/cat_deps_dir"
	depsdir=$CAT_DEPS_DIR
	echo "CAT_DEPS_DIR not found in env. Using default: $CAT_DEPS_DIR."
	warn_env=1
fi
boost_output_dir=$depsdir/boost
LD_LIBRARY_PATH_def="${depsdir}/boost/lib:${depsdir}/facebook/lib:${depsdir}/google/lib:${depsdir}/mongodb/lib:${depsdir}/zeromq/lib:./"
debs="git gcc g++ cmake curl libssl-dev ninja-build pkg-config libpython-dev"


function help {
	cat << EOF
$prog creates a _build directory ready to be compiled.
Syntax: $prog [options] [command]

Options:
    -j <number>          Parallel compilation jobs. Default is $jobs

Available commands:
    system_reqs            Installs apt dependencies. Requires sudo.
                             debian packages: $debs
    download deps          Obtain 3rd party libs.
    install deps           Compile & install 3rd party libs.
    build [debug]          Create and configure a new _build dir.
    devnet <cmd>           where cmd is one of:
        create 	           Create new private-test network with 1 node at _build.
        node <cmd>         Nodes in private-test network at _build. cmd one of:
            list           Current list of configured nodes, ordered by TCP port.
            new <port>     Add new node listening on the IP address $hostaddr
                           on the specified TCP port.
            info <port>    Displays information about the node at specified TCP port.
            rm <port>      Delete the node identified by its listening TCP port.
        clean              Deletes private-test network at _build
    cert generate <dir>    Tool to create new certificates.
EOF
	if [ "_$CAT_DEPS_DIR" == "_" ]; then
		echo "Environment variable CAT_DEPS_DIR not set. Required for storing source dependencies."
		echo "Default value is: $HOME/cat_deps_dir"
	else
		echo "Dependencies env.var CAT_DEPS_DIR is set to $CAT_DEPS_DIR"
	fi
	echo "Reminder: export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_def"
}

function exitok {
	if [ $warn_env -eq 1 ]; then
cat << EOF
Please export the environment variable CAT_DEPS_DIR

  export CAT_DEPS_DIR=$depsdir

Note: If you want the CAT_DEPS_DIR environment variable to persist across sessions make sure to include the last line in the ~/.profile or ~/.bashrc files.
EOF
	fi
	exit 0
}

function reqroot {
	if [ "_`whoami`" != "_root" ]; then
		echo "Please run as root. (or use sudo)"
		exit 1
	fi
}

#procedure cert generation. based on: https://raw.githubusercontent.com/tech-bureau/catapult-service-bootstrap/master/common/ruby/script/cert-generate.sh --output cert-generate.sh
function certGenerate {
	dir=$1
	shift
	mkdir -p $dir
	pushd $dir > /dev/null
		#ca.cnf
		cat <<EOF>ca.cnf
[ca]
default_ca = CA_default

[CA_default]
new_certs_dir = ./new_certs
database = index.txt
serial   = serial.dat

private_key = ca.key.pem
certificate = ca.cert.pem

policy = policy_catapult

[policy_catapult]
commonName              = supplied

[req]
prompt = no
distinguished_name = dn

[dn]
CN = peer-node-1-account
EOF
		#node.cnf
		cat <<EOF> node.cnf
[req]
prompt = no
distinguished_name = dn

[dn]
CN = peer-node-1
EOF
		mkdir new_certs && chmod 700 new_certs
		touch index.txt

		openssl="openssl"
		openssl_req="openssl req -batch"
		openssl_ca="openssl ca -batch"

		# create CA key
		$openssl genpkey -out ca.key.pem -outform PEM -algorithm ed25519
		$openssl pkey -inform pem -in ca.key.pem -text -noout
		$openssl pkey -in ca.key.pem -pubout -out ca.pubkey.pem

		# create CA cert and self-sign it
		$openssl_req -config ca.cnf -keyform PEM -key ca.key.pem -new -x509 -days 7300 -out ca.cert.pem
		$openssl x509 -in ca.cert.pem  -text -noout

		# create node key
		$openssl genpkey -out node.key.pem -outform PEM -algorithm ed25519
		$openssl pkey -inform pem -in node.key.pem -text -noout

		# create request
		$openssl_req -config node.cnf -key node.key.pem -new -out node.csr.pem
		$openssl_req  -text -noout -verify -in node.csr.pem

		# CA side
		# create serial
		$openssl rand -hex 19 > ./serial.dat

		# sign cert for 375 days
		$openssl_ca -config ca.cnf -days 375 -notext -in node.csr.pem -out node.crt.pem

		$openssl verify -CAfile ca.cert.pem node.crt.pem

		# finally create full crt
		cat node.crt.pem ca.cert.pem > node.full.crt.pem
	popd > /dev/null
}

function download_boost {
	local boost_ver=1_${1}_0
	local boost_ver_dotted=1.${1}.0
	curl -o boost_${boost_ver}.tar.gz -SL https://dl.bintray.com/boostorg/release/${boost_ver_dotted}/source/boost_${boost_ver}.tar.gz
	tar -xzf boost_${boost_ver}.tar.gz
	mv boost_${boost_ver} boost
}

function download_git_dependency {
	git clone git://github.com/${1}/${2}.git
	cd ${2}
	git checkout ${3}
	cd ..
}

function download_all {
	download_boost 75

	download_git_dependency google googletest release-1.10.0
	download_git_dependency google benchmark v1.5.2

	download_git_dependency mongodb mongo-c-driver 1.17.2
	download_git_dependency mongodb mongo-cxx-driver r3.6.1

	download_git_dependency zeromq libzmq v4.3.3
	download_git_dependency zeromq cppzmq v4.7.1

	download_git_dependency facebook rocksdb v6.13.3
}

function install_boost {
	pushd boost > /dev/null
		./bootstrap.sh with-toolset=clang --prefix=${boost_output_dir}
		b2_options=()
		b2_options+=(--prefix=${boost_output_dir})
		./b2 ${b2_options[@]} -j $jobs stage release
		./b2 install ${b2_options[@]}
	popd > /dev/null
}

function install_git_dependency {
	cd ${2}
	mkdir -p _build
	pushd _build > /dev/null
		cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX="$depsdir/${1}" ${cmake_options[@]} ..
		make -j $jobs && make install
	popd
}

function install_google_test {
	cmake_options=()
	cmake_options+=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
	install_git_dependency google googletest
}

function install_google_benchmark {
	cmake_options=()
	cmake_options+=(-DBENCHMARK_ENABLE_GTEST_TESTS=OFF)
	install_git_dependency google benchmark
}

function install_mongo_c_driver {
	cmake_options=()
	cmake_options+=(-DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF)
	cmake_options+=(-DENABLE_MONGODB_AWS_AUTH=OFF)
	cmake_options+=(-DENABLE_TESTS=OFF)
	cmake_options+=(-DENABLE_EXAMPLES=OFF)
	cmake_options+=(-DENABLE_SASL=OFF)
	install_git_dependency mongodb mongo-c-driver
}

function install_mongo_cxx_driver {
	cmake_options=()
	cmake_options+=(-DBOOST_ROOT=${boost_output_dir})
	cmake_options+=(-DCMAKE_CXX_STANDARD=17)
	install_git_dependency mongodb mongo-cxx-driver
}

function install_zmq_lib {
	cmake_options=()
	cmake_options+=(-DWITH_TLS=OFF)
	install_git_dependency zeromq libzmq
}

function install_zmq_cpp {
	cmake_options=()
	cmake_options+=(-DCPPZMQ_BUILD_TESTS=OFF)
	install_git_dependency zeromq cppzmq
}

function install_rocks {
	cmake_options=()
	cmake_options+=(-DPORTABLE=1)
	cmake_options+=(-DWITH_TESTS=OFF)
	cmake_options+=(-DWITH_TOOLS=OFF)
	cmake_options+=(-DWITH_BENCHMARK_TOOLS=OFF)
	cmake_options+=(-DWITH_CORE_TOOLS=OFF)
	cmake_options+=(-DWITH_GFLAGS=OFF)
	install_git_dependency facebook rocksdb
}

function install_all {
	declare -a installers=(
		install_boost
		install_google_test
		install_google_benchmark
		install_mongo_c_driver
		install_mongo_cxx_driver
		install_zmq_lib
		install_zmq_cpp
		install_rocks
	)
	for install in "${installers[@]}"
	do
		pushd source > /dev/null
			${install}
		popd > /dev/null
	done
}

#-------------------------------------------------------

function install_system_reqs {
	reqroot
	set -e
	apt update
	apt -y upgrade
	apt -y install $debs
	set +e
}

force_download=0

function download_deps {
	if [ -d $depsdir ]; then
		echo -n "Warning: ${depsdir} already exists. "
		if [ ${force_download} -eq 0 ]; then
			echo "Download skipped."
			return
		fi
		echo ""
	fi
	mkdir -p $depsdir
	set -e
	pushd $depsdir > /dev/null
		mkdir -p source
		pushd source > /dev/null
			download_all
		popd
	popd
	set +e
}

function install_deps {
	if [ ! -d ${boost_output_dir} ]; then
		download_deps
	fi
	pushd $depsdir > /dev/null
		install_all
	popd
}

#-------------------------------------------------------

function install_main {
	cmd=$1
	shift
	if [ "_$cmd" == "_system_reqs" ]; then
		install_system_reqs $@
		exitok
	elif [ "_$cmd" == "_deps" ]; then
		set_depsdir
		install_deps $@
		exitok
	fi
}


function download {
	cmd=$1
	shift
	if [ "_$cmd" == "_deps" ]; then
		force_download=1
		download_deps $@
		exitok
	fi
}

function make_build_dir {
	echo "building using ${jobs} jobs"
	echo "dependencies dir: ${depsdir}"
	if [ ! -d ${boost_output_dir} ]; then
		install_deps
	fi
	echo "dependencies OK at: ${depsdir}"
	sep=";"
	if [[ "$OSTYPE" == "darwin"* ]]; then
		sep=":"
	fi
	set -e
	mkdir -p _build
	pushd _build > /dev/null
		cmakeflags=""
		if [[ "_$1" == "_debug" ]]; then
			cxxflags="-g -O0 -rdynamic"
			cmakeflags="-DCMAKE_BUILD_TYPE=Debug -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON"
		else
			cxxflags="-O3"
			cmakeflags="-DCMAKE_BUILD_TYPE=RelWithDebInfo"
		fi
		BOOST_ROOT="${depsdir}/boost" cmake .. \
		-DCMAKE_PREFIX_PATH="${depsdir}/facebook${sep}${depsdir}/google${sep}${depsdir}/mongodb${sep}${depsdir}/zeromq" \
		-DCMAKE_INSTALL_PREFIX="$CMAKE_INSTALL_PREFIX" \
		$cmakeflags \
		-DCMAKE_CXX_FLAGS="$cxxflags" \
		\
		-GNinja
		ninja publish
	popd
	set +e
	echo "Sources are ready in directory _build"
	echo "Compile:"
	echo "  cd _build"
	echo "  ninja -v -j${jobs}"
	echo "Hints:"
    echo "  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_def"
	if [[ -f ../node_7900 ]]; then
		echo "devnet nodes: $prog devnet nodes"
		echo "Run node: cd _build/bin; ./catapult.server ../node_7900"
	else
		echo "Run: cd _build/bin; ./catapult.server .."
		echo "Create devnet: $prog devnet create"
	fi
	exitok
}

#-------------------------------------------------------

function setParam {
	file=$1
	p=$2
	v=$3
	echo "setParam $file $p $v"
	sed -i "s~^$p =.*~$p = $v~" $file || { echo "Error setting param." && exit 1; }
}

function node_keys_ {
	local __var_sk=$1
	local __var_pk=$2
	local __var_a=$3
	local __var_vpk=$4
	local __var_vpk_sk=$5
	local __var_vpk_pk=$6
	pwd=`pwd`
	if [[ ! -f addresses.csv ]]; then
		pushd ../bin > /dev/null
			echo "Generating harvesting address"
			r=`./catapult.tools.addressgen -f csv --count 1 --network private-test --output $pwd/addresses.csv --suppressConsole`
		popd > /dev/null
	fi
	if [[ ! -f addresses_vrf.csv ]]; then
		pushd ../bin > /dev/null
			echo "Generating address for VRF"
			r=`./catapult.tools.addressgen -f csv --count 1 --network private-test --output $pwd/addresses_vrf.csv --suppressConsole`
		popd > /dev/null
	fi
	if [[ ! -d votingKeys ]]; then
		echo "generating keys for node_$port"
		mkdir -p votingKeys
		pushd ../bin > /dev/null
			echo "Generating voting keys"
			eval vpk=`./catapult.tools.votingkey --output $pwd/votingKeys/private_key_tree1.dat | grep "loaded voting public key" | sed "s/loaded voting public key\: \(.*\)/\1/"`
			echo $vpk > $pwd/votingKeys/public_key
		popd > /dev/null
	fi
	eval $__var_a=`head -n1 addresses.csv | tr ',' ' ' | awk '{ print $1 }'`
	eval $__var_pk=`head -n1 addresses.csv | tr ',' ' ' | awk '{ print $3 }'`
	eval $__var_sk=`head -n1 addresses.csv | tr ',' ' ' | awk '{ print $4 }'`
	eval $__var_vpk=`cat votingKeys/public_key`
	eval $__var_vpk_sk=`head -n1 addresses_vrf.csv | tr ',' ' ' | awk '{ print $4 }'`
	eval $__var_vpk_pk=`head -n1 addresses_vrf.csv | tr ',' ' ' | awk '{ print $3 }'`
	eval vvar_a=\${$__var_a}
	eval vvar_pk=\${$__var_pk}
	eval vvar_sk=\${$__var_sk}
	eval vvar_vpk=\${$__var_vpk}
	eval vvar_vpk_sk=\${$__var_vpk_sk}
	eval vvar_vpk_pk=\${$__var_vpk_pk}
	cat << EOF
$__var_a $vvar_a
$__var_pk $vvar_pk
$__var_sk $vvar_sk
$__var_vpk $vvar_vpk
$__var_vpk_sk $vvar_vpk_sk
$__var_vpk_pk $vvar_vpk_pk
EOF
	if [[ "_$vvar_vpk_pk" == "_" ]]; then
		echo "Error $vvar_vpk_pk in address files at $pwd"
		exit 1
	fi
}

function node_keys {
	local port=$1
	local __var_sk=$2
	local __var_pk=$3
	local __var_a=$4
	local __var_vpk=$5
	local __var_vpk_sk=$6
	local __var_vpk_pk=$7
	mkdir -p node_$port
	pushd node_$port > /dev/null
		eval node_keys_ ${__var_sk} ${__var_pk} ${__var_a} ${__var_vpk} ${__var_vpk_sk} ${__var_vpk_pk}
	popd > /dev/null
	eval vvar_a=\${$__var_a}
	eval vvar_pk=\${$__var_pk}
	eval vvar_sk=\${$__var_sk}
	eval vvar_vpk=\${$__var_vpk}
	eval vvar_vpk_sk=\${$__var_vpk_sk}
	eval vvar_vpk_pk=\${$__var_vpk_pk}
	cat << EOF
node_keys:
  $__var_a $vvar_a
  $__var_pk $vvar_pk
  $__var_sk $vvar_sk
  $__var_vpk $vvar_vpk
  $__var_vpk_sk $vvar_vpk_sk
  $__var_vpk_pk $vvar_vpk_pk
EOF
}

function update_known_peers {
	file=peers-p2p.json
	cat << EOF > $file
{
  "_info": "this file contains a list of all trusted peers and can be shared",
  "knownPeers": [
EOF
	let n=`find . -maxdepth 1 -type d -name "node_*" | wc -l`
	for port in `find . -maxdepth 1 -type d -name "node_*" | sed "s~./node_\(.*\)~\1~" | sort -n`; do
		((n=n-1))
		pushd node_$port > /dev/null
			pushd certificate > /dev/null
				tlspk=`openssl pkey -pubin -in ca.pubkey.pem -noout -text | openssl dgst -sha256 -hex | awk '{ print $NF }'` || { echo "Error tls pubkey" && exit 1; }
				echo "TLS public key $tlspk"
			popd
#pwd
#cat resources/config-node.properties | grep "^host =" | sed "s/host = *\(.*\)/\1/"
			ipaddr=`cat resources/config-node.properties | grep "^host =" | sed "s/host = *\(.*\)/\1/"`
#ls -la resources/config-node.properties
			friendlyName=`cat resources/config-node.properties | grep "^friendlyName =" | sed "s/friendlyName = *\(.*\)/\1/"`
			roles=`cat resources/config-node.properties | grep "^roles =" | sed "s/roles = *\(.*\)/\1/"`
			cat << EOF >> ../$file
    {
      "publicKey": "$tlspk",
      "endpoint": {
        "host": "$ipaddr",
        "port": $port
      },
      "metadata": {
        "name": "$friendlyName",
        "roles": "$roles"
      }
    }
EOF
			[[ $n -gt 0 ]] && echo "    ," >> ../$file
		popd > /dev/null
	done
	cat << EOF >> $file
  ]
}
EOF
	pwd=`pwd`
	for port in `find . -maxdepth 1 -type d -name "node_*" | sed "s~./node_\(.*\)~\1~" | sort -n`; do
		echo "updating file $pwd/node_$port/resources/$file"
		cp $file node_$port/resources/
	done
	rm $file
}

function bootstrap_devnet_node_new__ {
	port=$1
	pwd=`pwd`
	echo "new node_$port. pwd=$pwd"
	[[ -d certificate ]] && echo "Error: certificate directory exists." && exit 1
	ipaddr=$hostaddr
	friendlyName="node_$port"
	version=""
	roles="IPv4,Peer,Api,Voting"
	file=resources/config-node.properties
	[[ ! -f $file ]] && echo "$file not found" && exit 1
	echo "file $pwd/$file"
	cat << EOF
	IP address $ipaddr
	friendlyName $friendlyName
	version $version
	roles $roles
EOF
	setParam $file host "$ipaddr"
	setParam $file friendlyName "$friendlyName"
	setParam $file version "$version"
	setParam $file roles "$roles"

	#1---------------
	echo "##Enable harvesting"
	file=resources/config-extensions-server.properties
	echo "file _build/$file"
	echo extension.harvesting=true
	setParam $file extension.harvesting true

	#2---------------
	node_keys_ sk pk a vpk vpksk vpkpk
	echo "##Configuring harvesting"
	file=resources/config-harvesting.properties
	echo "file _build/$file"
	#[[ -f ../../nemesis.harvesting_addresses.csv ]] || { echo "Error: missing file ../../nemesis.harvesting_addresses.csv" && exit 1; }
	#hsk=`head -n1 ../../nemesis.harvesting_addresses.csv | tr ',' ' ' | awk '{ print $4 }'`
	#r=`./catapult.tools.linker --resources ../ --type vrf --secret $sk2 --linkedPublicKey $hpk --output ../txes/vrf_tx0.bin`
	#sk2=`tail -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $4 }'`
	setParam $file harvesterSigningPrivateKey $sk
	setParam $file harvesterVrfPrivateKey $vpksk
	setParam $file enableAutoHarvesting true

	echo "##Generate TLS certificates"
	#1---------------
	certGenerate certificate

	#2---------------
	file=resources/config-user.properties
	echo "file _build/$file"
	setParam $file seedDirectory "../node_$port/seed"
	setParam $file dataDirectory "../node_$port/data"
	setParam $file certificateDirectory "../node_$port/certificate"
	setParam $file pluginsDirectory "."
	setParam $file votingKeysDirectory "../node_$port/votingKeys"

	mkdir data

#	echo "##List known peer nodes"
#	#1---------------
#	echo "Node is ready"
#	echo "Run the node: cd bin; ./catapult.server"
}

function bootstrap_devnet_node_new_ {
	port=$1
	nodeDir="node_$port"
	mkdir -p $nodeDir
	echo "copying network_config"
	cp ./resources $nodeDir/ -R
	setParam $nodeDir/resources/private-test.properties binDirectory ../node_$port/seed
	setParam $nodeDir/resources/private-test.properties transactionsDirectory ../node_$port/txes
	setParam $nodeDir/resources/config-logging-recovery.properties directory ../node_$port/logs/recovery
	setParam $nodeDir/resources/config-logging-broker.properties directory ../node_$port/logs/broker
	setParam $nodeDir/resources/config-logging-server.properties directory ../node_$port/logs/server
	setParam $nodeDir/resources/config-node.properties port $port
	cp ./seed $nodeDir/ -R
	pushd $nodeDir > /dev/null
		bootstrap_devnet_node_new__ $port
		echo "added $nodeDir at `pwd`"
	popd > /dev/null
	update_known_peers
}

function bootstrap_devnet_node_info_ {
	port=$1
	nodeDir="node_$port"
	[[ ! -d $nodeDir ]] && "Node doesn't exist at `pwd`" && return
	pushd $nodeDir > /dev/null
		cat << EOF
Node information:
port: $port
home: `pwd`
EOF
	popd > /dev/null
}


function bootstrap_devnet__build {
	[[ ! -x bin/catapult.tools.addressgen ]] && echo "Error: Binaries must be build first." && exit 1
	[[ -f resources/config-database.properties ]] && echo "Error: Directory resources already contains files." && exit 1
	[[ -f nemesis.addresses.csv ]] && echo "Error: file nemesis.addresses.csv already exists." && exit 1
    [[ -f resources/private-test.properties ]] && echo "Error: resources is not clean." && exit 1
	[[ -d seed/00000 ]] && echo "Error: Directory seed/00000 already exists." && exit 1
	[[ -d txes ]] && echo "Error: Directory txes already exists." && exit 1
	[[ -d node_7900 ]] && echo "Error: Directory node_7900 already exists." && exit 1

	echo "Copying properties templates."
	cp ../resources . -R
	pushd bin > /dev/null
		echo "Generating nemesis and harvester adresses."
		r=`./catapult.tools.addressgen -f csv --count 2 --network private-test --output ../nemesis.addresses.csv --suppressConsole`
	popd > /dev/null

	a1=`head -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $1 }'`
	pk1=`head -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $3 }'`
	sk1=`head -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $4 }'`

	a2=`tail -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $1 }'`
	pk2=`tail -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $3 }'`
	generation_hash_seed=$pk2
	#sk2=`tail -n1 nemesis.addresses.csv | tr ',' ' ' | awk '{ print $4 }'`

	node_keys 7900 hsk hpk ha vpk vpksk vpkpk

	supply="8'999'999'998'000'000"
	hsupply="17'000'000"

cat << EOF > nemesis.addresses.txt
NemesisSigner:
	address: $a1
	public: $pk1
	private: $sk1

nemesis node at 7900: mosaic recipient, FeeSink, voting:
	address: $ha
	public: $hpk
	private: $hsk
	voting public key: $vpk
	vrf account public key: $vpkpk
	vrf account secret key: $vpksk
EOF

	echo "file nemesis.addresses.txt:"
	cat nemesis.addresses.txt

	echo "file resources/private-test.properties:"
cat << EOF > resources/private-test.properties
# properties for nemesis block compatible with catapult signature scheme used in tests
# for proper generation, update following config-network properties:
# - enableVerifiableState = false
# - enableVerifiableReceipts = false

[nemesis]

networkIdentifier = private-test
nemesisGenerationHashSeed = $generation_hash_seed
nemesisSignerPrivateKey = $sk1

[cpp]

cppFileHeader =

[output]

cppFile =
binDirectory = ../seed

[namespaces]

cat = true
cat.currency = true
cat.harvest = true

[namespace>cat]

duration = 0

[mosaics]

cat:currency = true
cat:harvest = true

[mosaic>cat:currency]

divisibility = 6
duration = 0
supply = $supply
isTransferable = true
isSupplyMutable = false
isRestrictable = false

[distribution>cat:currency]

$ha = $supply

[mosaic>cat:harvest]

divisibility = 3
duration = 0
supply = $hsupply
isTransferable = true
isSupplyMutable = true
isRestrictable = false

[distribution>cat:harvest]

$ha = $hsupply

# additional transactions are appended after generated transactions
# transactions will be sorted based on file names

[transactions]

transactionsDirectory = ../txes

EOF
	file="resources/config-network.properties"
	echo "updating file $file"
	setParam $file initialCurrencyAtomicUnits $supply
	setParam $file totalChainImportance $hsupply
	setParam $file maxHarvesterBalance $hsupply
	setParam $file identifier private-test
	setParam $file nemesisSignerPublicKey $pk1
	setParam $file generationHashSeed $generation_hash_seed
	setParam $file harvestNetworkFeeSinkAddress $ha
	setParam $file mosaicRentalFeeSinkAddress $ha
	setParam $file namespaceRentalFeeSinkAddress $ha

	mkdir -p seed/00000
	mkdir txes

	pushd bin > /dev/null
		echo "Linking VRF for harvesting into address $ha, signed by harverter account."
		r=`./catapult.tools.linker --resources ../ --type vrf --secret $hsk --linkedPublicKey $vpkpk --output ../txes/vrf_tx0.bin`
		[[ $? -ne 0 ]] && echo "Error" && exit 1
	popd > /dev/null

	pushd bin > /dev/null
		echo "Generating voting tx"
		r=`./catapult.tools.linker --resources ../ --type voting --secret $hsk --linkedPublicKey $vpk --output ../txes/voting_tx0.bin`
		[[ $? -ne 0 ]] && echo "Error" && exit 1
	popd > /dev/null

	echo "Obtaining mosaic Ids"
	pushd bin > /dev/null

#cat ../resources/private-test.properties
#pwd
#ls -la ../resources/private-test.properties
#echo "./catapult.tools.nemgen --nemesisProperties ../resources/private-test.properties  >/tmp/mosaics 2>&1"
#exit 0
		r=`./catapult.tools.nemgen --nemesisProperties ../resources/private-test.properties  >/tmp/mosaics 2>&1`
		[[ $? -eq 0 ]] && echo "Error. The nemgen was expected to fail at this stage, but it succeed." && exit 1
	popd > /dev/null
	mosaic_cash=`cat /tmp/mosaics | grep " Mosaic Summary" -A20 | grep " - cat:currency" | sed "s/.*cat:currency (\([A-F0-9]*\)).*/\1/"`
	mosaic_harv=`cat /tmp/mosaics | grep " Mosaic Summary" -A20 | grep " - cat:harvest" | sed "s/.*cat:harvest (\([A-F0-9]*\)).*/\1/"`
	cat /tmp/mosaics
	[[ "_mosaic_cash" == "_" ]] && echo "Error mosaic cash." && exit 1
	[[ "_mosaic_harv" == "_" ]] && echo "Error mosaic harvest." && exit 1
	rm -f /tmp/mosaics
	echo "mosaics ids: cash \"$mosaic_cash\" harvest \"$mosaic_harv\""

	echo "updating file $file"
	sed -i "s/^currencyMosaicId = .*/currencyMosaicId = 0x$mosaic_cash/" $file
	sed -i "s/^harvestingMosaicId = .*/harvestingMosaicId = 0x$mosaic_harv/" $file

	echo "Generating nemesis block"
	pushd bin > /dev/null
		r=`./catapult.tools.nemgen --nemesisProperties ../resources/private-test.properties`
	popd > /dev/null
	echo "Configuring nemesis node."
	bootstrap_devnet_node_new_ 7900
}

function readymsg {
	pushd _build >/dev/null
		cat << EOF
Ready.
  configure aditional nodes: $prog devnet node
EOF
		for port in `find . -maxdepth 1 -type d -name "node_*" | sed "s~./node_\(.*\)~\1~" | sort -n`; do
			echo "  start node $port: cd _build/bin; ./catapult.server ../node_$port"
		done
	popd > /dev/null
}

function bootstrap_devnet_create {
	[[ ! -d _build ]] && echo "required _build dir" && exit 1
	pushd _build >/dev/null
		pushd bin >/dev/null
			[[ ! -f  ./catapult.tools.nemgen ]] && echo "Please build binaries first: cd _build; ninja -j${jobs}" && exit 1
			./catapult.tools.nemgen --help > /dev/null 2>&1
			[[ $? -ne 1 ]] && echo "Please: export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_def" && exit 1
		popd
		bootstrap_devnet__build $@
	popd > /dev/null
	readymsg
	exit 0
}

function bootstrap_devnet_node_clean {
	[[ ! -d _build ]] && echo "required _build dir" && exit 1
	pushd _build >/dev/null
#		pwd
#		echo "find . -type d -name \"node_*\" -exec rm -rf {} \;"
		find . -maxdepth 1 -type d -name "node_*" -exec rm -rf {} \; >/dev/null 2>&1
	popd > /dev/null
}

function bootstrap_devnet_node_list {
	[[ ! -d _build ]] && echo "required _build dir" && exit 1
	pushd _build >/dev/null
		echo "IP Address $hostaddr"
		n=`find . -maxdepth 1 -type d -name "node_*" | wc -l`
		find . -maxdepth 1 -type d -name "node_*" | sed "s~./node_\(.*\)~\1~" | sort -n
		echo "$n nodes configured in `pwd`"
	popd > /dev/null
	exit 0
}

function bootstrap_devnet_node_new {
	[[ ! -d _build ]] && echo "required _build dir" && exit 1
	port=$1
	shift
	[[ "_$port" == "_" ]] && echo "Error. Specify port." && exit 1
	pushd _build >/dev/null
		nodeDir="node_$port"
		[[ -d $nodeDir ]] && echo "Error: $nodeDir already exist" && exit 1
		bootstrap_devnet_node_new_ $port
	popd > /dev/null
	readymsg
	exit 0
}

function bootstrap_devnet_node_info {
	[[ ! -d _build ]] && echo "required _build dir" && exit 1
	port=$1
	shift
	[[ "_$port" == "_" ]] && echo "Error. Specify port." && exit 1
	pushd _build >/dev/null
		bootstrap_devnet_node_info_ $port
	popd > /dev/null
	exit 0
}

function bootstrap_devnet_node_rm {
	[[ ! -d _build ]] && echo "required _build dir" && exit 1
	port=$1
	shift
	[[ "_$port" == "_" ]] && echo "Error. Specify port to delete." && exit 1
	pushd _build >/dev/null
		nodeDir="node_$port"
		[[ ! -d $nodeDir ]] && echo "Error Directory $nodeDir not found" && exit 1
		rm $nodeDir -rf
		update_known_peers
	popd > /dev/null
	echo "deleted $nodeDir"
	exit 0
}

function bootstrap_devnet_node {
	cmd=$1
	shift
	[[ "_$cmd" == "_list" ]] && bootstrap_devnet_node_list $@
	[[ "_$cmd" == "_new" ]] && bootstrap_devnet_node_new $@
	[[ "_$cmd" == "_info" ]] && bootstrap_devnet_node_info $@
	[[ "_$cmd" == "_rm" ]] && bootstrap_devnet_node_rm $@
	echo "Error devnet node at $cmd"
	help
	exit 1
}

function bootstrap_devnet_clean {
	bootstrap_devnet_node_clean
	[[ ! -d _build ]] && echo "required _build dir." && exit 1
	pushd _build >/dev/null
		if [[ -f resources/config-network.properties ]]; then
			rm -f resources/*.properties
			rm -f resources/*.json
			rm -f resources/CMakeLists.txt
			echo "deleted files in _build/resources."
		fi
		if [[ -f nemesis.addresses.csv ]]; then
			rm -f nemesis.addresses.csv
			#rm -f nemesis.harvesting_addresses.csv
			echo "deleted wallet addresses."
		fi
		rm -r seed/00000 >/dev/null 2>&1 && echo "deleted nemesis block."
		rm -r txes >/dev/null 2>&1 && echo "deleted nemesis block transactions."
		rm -r data >/dev/null 2>&1 && echo "deleted data."
		rm nemesis.addresses.txt >/dev/null 2>&1 && echo "deleted nemesis.addresses."
		rm -r seed >/dev/null 2>&1 && echo "deleted seed."
	popd > /dev/null
	exit 0
}

function bootstrap_devnet {
	cmd=$1
	shift
	if [ "_$cmd" == "_create" ]; then
		bootstrap_devnet_create $@
	elif [ "_$cmd" == "_node" ]; then
		bootstrap_devnet_node $@
	elif [ "_$cmd" == "_clean" ]; then
		bootstrap_devnet_clean $@
	fi
	echo "Error $cmd"
	help
	exit 1
}

function tool_cert_generate {
	certGenerate $@
	exit $?
}

#-------------------------------------------------------

function bootstrap {
	cmd=$1
	shift
	if [ "_$cmd" == "_devnet" ]; then
		bootstrap_devnet $@
	fi
	echo "bootstrap error at $cmd"
	help
	exit 1
}

function tool_cert {
	cmd=$1
	shift
	if [ "_$cmd" == "_generate" ]; then
		tool_cert_generate $@
	fi
	echo "tool_cert error at $cmd"
	help
	exit 1
}

#-------------------------------------------------------

cmd=""
while [ true ]; do
	opt=$1
	shift
	if [ "_$opt" == "_-j" ]; then
		jobs=$1
		shift
		echo "jobs $jobs"
		continue
	else
		cmd=$opt
		break
	fi
done

if [ "_$cmd" == "_install" ]; then
	install_main $@
elif [ "_$cmd" == "_download" ]; then
	download $@
elif [ "_$cmd" == "_build" ]; then
	make_build_dir $@
elif [ "_$cmd" == "_bootstrap" ]; then
	bootstrap $@
elif [ "_$cmd" == "_devnet" ]; then #shortcut for 'bootstrap devnet'
	bootstrap_devnet $@
elif [ "_$cmd" == "_cert" ]; then
	tool_cert $@
fi

echo "Error at $cmd"
#error flow
help
exit 1

