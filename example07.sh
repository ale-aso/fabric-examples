#!/bin/bash

set -e

source $(dirname $0)/common.sh

curDir=$PWD
trap cleanup EXIT
function cleanup {
  cd $curDir
}

ChannelName=my-ch
CCName=my-cc
CollName=my-collection

fabricDir=$GOPATH/src/github.com/hyperledger/fabric/
artifactsDir=/tmp/$(basename $0).mat/

if test -d $artifactsDir
then
  rm -rf $artifactsDir
fi
mkdir $artifactsDir

ordererOrg=myordererorg
applicationOrg=myapplicationorg
newApplicationOrg=mynewapplicationorg

ordererOrgDir=$artifactsDir/crypto-config/ordererOrganizations/$ordererOrg
applicationOrgDir=$artifactsDir/crypto-config/peerOrganizations/$applicationOrg
newApplicationOrgDir=$artifactsDir/crypto-config/peerOrganizations/$newApplicationOrg

genBlockMain=$artifactsDir/$ChannelName.block
ordBlockMain=$artifactsDir/$ChannelName-orderer.block
genTransMain=$artifactsDir/$ChannelName-channel.tx

CONFIGTXGEN_CMD=$fabricDir/.build/bin/configtxgen
CONFIGTXLTR_CMD=$fabricDir/.build/bin/configtxlator
PEER_CMD=$fabricDir/.build/bin/peer
CRYPTOGEN_CMD=$fabricDir/.build/bin/cryptogen
BLOCKPARSER_CMD=$(readlink -f $(dirname $0))/blockparser

configtxgenFile=$artifactsDir/configtx.yaml
cat <<- EOF > $configtxgenFile
---
Organizations:
    - &OrdererOrg
        Name: $ordererOrg
        ID: $ordererOrg
        MSPDir: $ordererOrgDir/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('$ordererOrg.member')"
            Writers:
                Type: Signature
                Rule: "OR('$ordererOrg.member')"
            Admins:
                Type: Signature
                Rule: "OR('$ordererOrg.admin')"

    - &$applicationOrg
        Name: $applicationOrg
        ID: $applicationOrg
        MSPDir: $applicationOrgDir/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('$applicationOrg.admin', '$applicationOrg.peer', '$applicationOrg.client')"
            Writers:
                Type: Signature
                Rule: "OR('$applicationOrg.admin', '$applicationOrg.client')"
            Admins:
                Type: Signature
                Rule: "OR('$applicationOrg.admin')"
        AnchorPeers:
            - Host: $applicationOrg
              Port: 7051

    - &$newApplicationOrg
        Name: $newApplicationOrg
        ID: $newApplicationOrg
        MSPDir: $newApplicationOrgDir/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('$newApplicationOrg.admin', '$newApplicationOrg.peer', '$newApplicationOrg.client')"
            Writers:
                Type: Signature
                Rule: "OR('$newApplicationOrg.admin', '$newApplicationOrg.client')"
            Admins:
                Type: Signature
                Rule: "OR('$newApplicationOrg.admin')"
        AnchorPeers:
            - Host: $newApplicationOrg
              Port: 7051

Capabilities:
    Global: &ChannelCapabilities
        V1_1: true
    Orderer: &OrdererCapabilities
        V1_1: true
    Application: &ApplicationCapabilities
        V1_2: true

Application: &ApplicationDefaults
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
    Capabilities:
        <<: *ApplicationCapabilities

Orderer: &OrdererDefaults
    OrdererType: solo
    Addresses:
        - $ordererOrg:7050
    BatchTimeout: 10ms
    BatchSize:
        MaxMessageCount: 10
        AbsoluteMaxBytes: 99 MB
        PreferredMaxBytes: 512 KB
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
        BlockValidation:
            Type: ImplicitMeta
            Rule: "ANY Writers"
    Capabilities:
        <<: *OrdererCapabilities

Channel: &ChannelDefaults
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
    Capabilities:
        <<: *ChannelCapabilities

Profiles:
    TwoOrgsOrdererGenesis:
        <<: *ChannelDefaults
        Orderer:
            <<: *OrdererDefaults
            Organizations:
                - *OrdererOrg
        Consortiums:
            SampleConsortium:
                Organizations:
                    - *$applicationOrg
                    - *$newApplicationOrg
    TwoOrgsChannel:
        Consortium: SampleConsortium
        Application:
            <<: *ApplicationDefaults
            Organizations:
                - *$applicationOrg
                - *$newApplicationOrg

EOF

cryptogenCfgFile=$artifactsDir/crypto-config.yaml
cat <<- EOF > $cryptogenCfgFile
OrdererOrgs:
  - Name: $ordererOrg
    Domain: $ordererOrg
    Specs:
      - Hostname: orderer
        CommonName: orderer
PeerOrgs:
  - Name: $applicationOrg
    Domain: $applicationOrg
    EnableNodeOUs: true
    Specs:
      - Hostname: peer
        CommonName: peer
      - Hostname: peer1
        CommonName: peer1
    Users:
      Count: 1
  - Name: $newApplicationOrg
    Domain: $newApplicationOrg
    EnableNodeOUs: true
    Specs:
      - Hostname: peer
        CommonName: peer
    Users:
      Count: 1
EOF

dockerComposeFile=$artifactsDir/network.yaml
cat <<- EOF > $dockerComposeFile
version: '3.5'

services:

  $ordererOrg:
    container_name: $ordererOrg
    image: hyperledger/fabric-orderer
    networks:
      - fabric-net
    environment:
      - ORDERER_GENERAL_LOGLEVEL=debug
      - ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
      - ORDERER_GENERAL_GENESISMETHOD=file
      - ORDERER_GENERAL_LOCALMSPID=$ordererOrg
      - ORDERER_GENERAL_GENESISFILE=/var/hyperledger/orderer/genesis.block
      - ORDERER_GENERAL_LOCALMSPDIR=/var/hyperledger/orderer/msp
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric
    command: orderer
    volumes:
    - $ordBlockMain:/var/hyperledger/orderer/genesis.block
    - $ordererOrgDir/orderers/orderer/msp:/var/hyperledger/orderer/msp
    ports:
      - 7050:7050

  $applicationOrg:
    container_name: $applicationOrg
    image: hyperledger/fabric-peer
    networks:
      - fabric-net
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric-net
      - CORE_PEER_TLS_ENABLED=false
      - CORE_LOGGING_LEVEL=DEBUG
      - CORE_PEER_ID=$applicationOrg
      - CORE_PEER_ADDRESS=$applicationOrg:7051
      - CORE_PEER_CHAINCODEADDRESS=$applicationOrg:7052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
      - CORE_PEER_LOCALMSPID=$applicationOrg
      - CORE_PEER_GOSSIP_USELEADERELECTION=true
      - CORE_PEER_GOSSIP_ORGLEADER=false
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=$applicationOrg:7051
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    volumes:
        - /var/run/:/host/var/run/
        - $applicationOrgDir/peers/peer/msp:/etc/hyperledger/fabric/msp
    ports:
      - 7051:7051
      - 7052:7052
      - 7053:7053

  ${applicationOrg}1:
    container_name: ${applicationOrg}1
    image: hyperledger/fabric-peer
    networks:
      - fabric-net
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric-net
      - CORE_PEER_TLS_ENABLED=false
      - CORE_LOGGING_LEVEL=DEBUG
      - CORE_PEER_ID=$applicationOrg
      - CORE_PEER_ADDRESS=${applicationOrg}1:7051
      - CORE_PEER_CHAINCODEADDRESS=${applicationOrg}1:7052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
      - CORE_PEER_LOCALMSPID=$applicationOrg
      - CORE_PEER_GOSSIP_USELEADERELECTION=true
      - CORE_PEER_GOSSIP_ORGLEADER=false
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=${applicationOrg}1:7051
      - CORE_PEER_GOSSIP_BOOTSTRAP=$applicationOrg:7051
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    volumes:
        - /var/run/:/host/var/run/
        - $applicationOrgDir/peers/peer1/msp:/etc/hyperledger/fabric/msp
    ports:
      - 8051:7051
      - 8052:7052
      - 8053:7053

  $newApplicationOrg:
    container_name: $newApplicationOrg
    image: hyperledger/fabric-peer
    networks:
      - fabric-net
    environment:
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=fabric-net
      - CORE_PEER_TLS_ENABLED=false
      - CORE_LOGGING_LEVEL=DEBUG
      - CORE_PEER_ID=$newApplicationOrg
      - CORE_PEER_ADDRESS=$newApplicationOrg:7051
      - CORE_PEER_CHAINCODEADDRESS=$newApplicationOrg:7052
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
      - CORE_PEER_LOCALMSPID=$newApplicationOrg
      - CORE_PEER_GOSSIP_USELEADERELECTION=true
      - CORE_PEER_GOSSIP_ORGLEADER=false
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    volumes:
        - /var/run/:/host/var/run/
        - $newApplicationOrgDir/peers/peer/msp:/etc/hyperledger/fabric/msp
    ports:
      - 9051:7051
      - 9052:7052
      - 9053:7053

networks:
  fabric-net:
    name: fabric-net
EOF

collectionConfigFile=$artifactsDir/collectionconfig.json
cat <<- EOF > $collectionConfigFile
[
        {
                "name": "$CollName",
                "policy": "OR('$applicationOrg.member', '$applicationOrg.admin')",
                "requiredPeerCount": 1,
                "maxPeerCount": 1,
                "blockToLive":1000000
        }
]
EOF

cd $artifactsDir
$CRYPTOGEN_CMD generate --config=$cryptogenCfgFile

cd $curDir

# generating genesis block (main channel)
$CONFIGTXGEN_CMD -profile TwoOrgsOrdererGenesis -outputBlock $ordBlockMain --configPath $artifactsDir
$CONFIGTXGEN_CMD -profile TwoOrgsChannel -outputCreateChannelTx $genTransMain -channelID $ChannelName --configPath $artifactsDir

killall -9 peer || true
docker ps -a | awk '{print $1}' | xargs docker kill || true
docker ps -a | awk '{print $1}' | xargs docker rm || true
docker network rm fabric-net || true
docker image ls | grep $CCName | awk '{print $3}' | xargs docker rmi -f || true
runStep docker-compose -f $dockerComposeFile up -d

sleep .2

# creating channel
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD channel create -o 127.0.0.1:7050 -c $ChannelName -f $genTransMain --outputBlock $genBlockMain

# joining channel
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD channel join -b $genBlockMain

# joining channel
env CORE_PEER_ADDRESS=127.0.0.1:8051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD channel join -b $genBlockMain

# joining channel
env CORE_PEER_ADDRESS=127.0.0.1:9051 CORE_PEER_LOCALMSPID=$newApplicationOrg CORE_PEER_MSPCONFIGPATH=$newApplicationOrgDir/users/Admin@mynewapplicationorg/msp/ \
$PEER_CMD channel join -b $genBlockMain

# install chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD chaincode install -n $CCName -v 1 -p github.com/hyperledger/fabric/examples/chaincode/go/map

# install chaincode
env CORE_PEER_ADDRESS=127.0.0.1:8051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD chaincode install -n $CCName -v 1 -p github.com/hyperledger/fabric/examples/chaincode/go/map

# install chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:9051 CORE_PEER_LOCALMSPID=$newApplicationOrg CORE_PEER_MSPCONFIGPATH=$newApplicationOrgDir/users/Admin@mynewapplicationorg/msp/ \
$PEER_CMD chaincode install -n $CCName -v 1 -p github.com/hyperledger/fabric/examples/chaincode/go/map

# instantiate chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/Admin@myapplicationorg/msp/ \
$PEER_CMD chaincode instantiate -C $ChannelName -n $CCName -v 1 -c '{"Args":[""]}' --collections-config $collectionConfigFile

sleep 1

# query chaincode
env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c '{"Args":["get","foo"]}'

# invoke chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode invoke -n $CCName -C $ChannelName  -c '{"Args":["put","foo","bar"]}'

sleep 1

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c'{"Args":["get","foo"]}'

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:8051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c'{"Args":["get","foo"]}'

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:9051 CORE_PEER_LOCALMSPID=$newApplicationOrg CORE_PEER_MSPCONFIGPATH=$newApplicationOrgDir/users/User1@mynewapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c'{"Args":["get","foo"]}'

# invoke chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode invoke -n $CCName -C $ChannelName  -c "{\"Args\":[\"putPrivate\",\"$CollName\",\"fooprivate\",\"barprivate\"]}"

sleep 1

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c "{\"Args\":[\"getPrivate\",\"$CollName\",\"fooprivate\"]}"

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:8051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c "{\"Args\":[\"getPrivate\",\"$CollName\",\"fooprivate\"]}"

# query chaincode
runStep env CORE_PEER_ADDRESS=127.0.0.1:9051 CORE_PEER_LOCALMSPID=$newApplicationOrg CORE_PEER_MSPCONFIGPATH=$newApplicationOrgDir/users/User1@mynewapplicationorg/msp/ \
$PEER_CMD chaincode query -n $CCName -C $ChannelName  -c "{\"Args\":[\"getPrivate\",\"$CollName\",\"fooprivate\"]}" || true

echo "env CORE_PEER_ADDRESS=127.0.0.1:7051 CORE_PEER_LOCALMSPID=$applicationOrg CORE_PEER_MSPCONFIGPATH=$applicationOrgDir/users/User1@myapplicationorg/msp/ \
$PEER_CMD channel fetch 1 /dev/stdout -c my-ch | $BLOCKPARSER_CMD"
