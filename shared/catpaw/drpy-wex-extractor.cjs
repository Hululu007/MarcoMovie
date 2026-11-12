// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Data-only interoperability for reviewed WEX Guard plugins: no native, DEX, or imported script execution.
const crypto = require('node:crypto');
const { zipMember, Dex, MAX } = require('./drpy-guard-extractor.cjs');
const { decodeUtf8Fatal } = require('./drpy-t4-extractor.cjs');

const VOD_WEX_ADAPTERS = Object.freeze(["wexappv7-v1","wexguazi-v1","wexduboku-v1","wexwencai-v1","wexfengye-v1","wexjianpian-v1","wexjuxiafan-v1","wexrebo-v1","wexbobo-v1","wexikanbot-v1","wexyiys-v1","wexhanxiaoquan-v1"]);
const WEX_ADAPTERS = Object.freeze(["wexappv7-v1","wexguazi-v1","wexduboku-v1","wexwencai-v1","wexfengye-v1","wexjianpian-v1","wexjuxiafan-v1","wexrebo-v1","wexbobo-v1","wexikanbot-v1","wexyiys-v1","wexhanxiaoquan-v1","wexduoduo-v1","wexhuban-v1","wexkuaiying-v1","wexlabi-v1","wexmuou-v1","wexshandian-v1","wexxiaopan-v1","wexzhizhen-v1","wexwogg-v1","wexhuajuan-v1","wexjutou-v1","wexzhinan-v1","wexwoniu-v1","wexpianku-v1","wexqiwei-v1","wexyidong-v1","wexaipanso-v1","wexhaiyin-v1","wexquanpan-v1","wexkaka-v1"]);

const PROFILES = {
  "9848e4d7b2d81b193ec458459d21f9cada92e0374a424a9ddaeaf440736af178": {
    "nativeSha": "646f8bb4dda60536f8d71f537892f4631053e9cc2a21d458015bd0bb143a1fb5",
    "nativeSize": 48680,
    "spiders": {
      "wexappv7-v1": {
        "cls": "Lcom/github/catvod/spider/WexAppV7;",
        "methods": {
          "<init>": [
            "<init>",
            "6404b876a219d6df2cfc71b1197029c1d87af3db868ae84bbe5dd583cbec2dbf"
          ],
          "init": [
            "init",
            "dd4c31551fb2d9a69ef103e32c8a23414755124ddcf1191d11fcd85dd231eca6"
          ],
          "homeContent": [
            "homeContent",
            "7501aecefccc79c71118f68c9cb0581a11e07f79809b66ee5ce1166567932e82"
          ],
          "categoryContent": [
            "categoryContent",
            "d463796ff96b2fa6b5a10c6c316a862e9f20bf1dddfddf1bfc5c6f9ba48930b9"
          ],
          "detailContent": [
            "detailContent",
            "0489d77b127218f8d38a4ab04c24453fbf8a3b6f10a17c46171000cbf2217a2a"
          ],
          "playerContent": [
            "playerContent",
            "8eebe8ba39db6a26f1bd9f4190ce6910a15866c2317ee6f46885d6ecf93bad22"
          ],
          "searchContent": [
            "searchContent",
            "23e8f452b7902deb765ac32af07f9142e36e54c8ea8cf99278b09f60a6222997"
          ]
        },
        "literals": {
          "apkPrefix": [
            "detailContent",
            "0489d77b127218f8d38a4ab04c24453fbf8a3b6f10a17c46171000cbf2217a2a",
            58
          ],
          "apkSuffix": [
            "detailContent",
            "0489d77b127218f8d38a4ab04c24453fbf8a3b6f10a17c46171000cbf2217a2a",
            70
          ],
          "playerAesIv": [
            "playerContent",
            "8eebe8ba39db6a26f1bd9f4190ce6910a15866c2317ee6f46885d6ecf93bad22",
            9
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexguazi-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiGuaZi;",
        "methods": {
          "<clinit>": [
            "<clinit>",
            "28d973f2c4bff9361d714e5999e63db6a26e2bc83d67fc1e4e5b54abe2d41af7"
          ],
          "<init>": [
            "<init>",
            "5e8c3e857bc00c34d6b1de08f34fb168b457c43e39442dccd25265b46e9ed02c"
          ],
          "init": [
            "init",
            "bb0c4c1b1aa0484e595c0bbb7dfabb24d4dbde2b80c769e8f60da0edb5d185a4"
          ],
          "homeContent": [
            "homeContent",
            "94910237ae98a96c51d8c63e4319da8d9f54c0f2c2703ebcf1c0e19b034a88db"
          ],
          "categoryContent": [
            "categoryContent",
            "c2b22c056450d574f20b376d5c12fbcd31f3a52e5be8b89f49956a6fa00178d3"
          ],
          "detailContent": [
            "detailContent",
            "ecb5f3e7bc56856417bfaf4795776324a0ed32fb754c01548dde64841520a6a9"
          ],
          "playerContent": [
            "playerContent",
            "43b87c571cdfa0912dcd237b511b449b51e69be74a0b97bb7b74e9b07458c9ec"
          ],
          "searchContent": [
            "searchContent",
            "3680f0bb9b9396b642d237622d2d8d98b3d81e66433f5a13ccaeca412cad576f"
          ]
        },
        "literals": {
          "defaultHost": [
            "<clinit>",
            "28d973f2c4bff9361d714e5999e63db6a26e2bc83d67fc1e4e5b54abe2d41af7",
            0
          ],
          "host1": [
            "<clinit>",
            "28d973f2c4bff9361d714e5999e63db6a26e2bc83d67fc1e4e5b54abe2d41af7",
            2
          ],
          "host2": [
            "<clinit>",
            "28d973f2c4bff9361d714e5999e63db6a26e2bc83d67fc1e4e5b54abe2d41af7",
            4
          ],
          "host3": [
            "<clinit>",
            "28d973f2c4bff9361d714e5999e63db6a26e2bc83d67fc1e4e5b54abe2d41af7",
            6
          ],
          "host4": [
            "<clinit>",
            "28d973f2c4bff9361d714e5999e63db6a26e2bc83d67fc1e4e5b54abe2d41af7",
            8
          ],
          "defaultRef": [
            "<init>",
            "5e8c3e857bc00c34d6b1de08f34fb168b457c43e39442dccd25265b46e9ed02c",
            20
          ],
          "phoneModel": [
            "j",
            "f46c4370f99a550f051685f2379f4e88d8b22586a06d5a08d2354c62f86b6eb5",
            25
          ],
          "publicKey": [
            "r",
            "9c981d1e251911b8329e5bbf88d9bf16d9f0a5f49958867ddb973bc29aa01878",
            73
          ],
          "signatureSuffix": [
            "r",
            "9c981d1e251911b8329e5bbf88d9bf16d9f0a5f49958867ddb973bc29aa01878",
            279
          ],
          "privateKey": [
            "m",
            "7f559fbaef7453167321f494760c6c9eaef4bff7bda5159153f48d89f76a952b",
            147
          ],
          "utdidKey": [
            "p",
            "006bcef62b41189ff1de528e68cf02f457970bd75acb9930bc7159f4b0733f64",
            14
          ],
          "userAgent": [
            "m",
            "7f559fbaef7453167321f494760c6c9eaef4bff7bda5159153f48d89f76a952b",
            10
          ],
          "ver": [
            "m",
            "7f559fbaef7453167321f494760c6c9eaef4bff7bda5159153f48d89f76a952b",
            18
          ],
          "version": [
            "m",
            "7f559fbaef7453167321f494760c6c9eaef4bff7bda5159153f48d89f76a952b",
            25
          ],
          "pkg": [
            "m",
            "7f559fbaef7453167321f494760c6c9eaef4bff7bda5159153f48d89f76a952b",
            37
          ],
          "code": [
            "m",
            "7f559fbaef7453167321f494760c6c9eaef4bff7bda5159153f48d89f76a952b",
            42
          ],
          "playUa": [
            "playerContent",
            "43b87c571cdfa0912dcd237b511b449b51e69be74a0b97bb7b74e9b07458c9ec",
            6
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexduboku-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiDuBoKu;",
        "methods": {
          "<init>": [
            "<init>",
            "1b754a658a9eabd37b5457bd8f39499657cdc5f20a418e4b6f13312bd7597768"
          ],
          "homeContent": [
            "homeContent",
            "d2c7cec30cdc1edecc1efab432c2ec2efc1e4c9309aabeea39b09e1d63b9f38f"
          ],
          "categoryContent": [
            "categoryContent",
            "fd3a6e17dbda7fc1f5cd5dfaaa3d83add83eae3280ae37ee0056c92c227957f9"
          ],
          "detailContent": [
            "detailContent",
            "8913b9b3bca6c1f6b6526b4db75a76f9f126a4260996a99942ebe1f839b96756"
          ],
          "playerContent": [
            "playerContent",
            "fcd5c4b5191f1b0c29ca4b831dafbcd4ffb25fcc4bdde99491d4264f3dc9ea1b"
          ],
          "searchContent": [
            "searchContent",
            "3a56cef026a2ae11ab5af4da1b37c7d3f472f85b68ccffada1d47b97de8725df"
          ]
        },
        "literals": {
          "defaultHost": [
            "categoryContent",
            "fd3a6e17dbda7fc1f5cd5dfaaa3d83add83eae3280ae37ee0056c92c227957f9",
            90
          ],
          "alphabetPlain": [
            "b",
            "bd55b2d3eb9ab245442445f7676159e631678fb82548b9e4d23fc09718a67bb4",
            17
          ],
          "alphabetShifted": [
            "b",
            "bd55b2d3eb9ab245442445f7676159e631678fb82548b9e4d23fc09718a67bb4",
            24
          ],
          "apiReferer": [
            "e",
            "d5213587139cef977754f921a63aa35a810690f2766bb62092ce99390605bbf5",
            14
          ],
          "userAgent": [
            "e",
            "d5213587139cef977754f921a63aa35a810690f2766bb62092ce99390605bbf5",
            6
          ],
          "playOrigin": [
            "playerContent",
            "fcd5c4b5191f1b0c29ca4b831dafbcd4ffb25fcc4bdde99491d4264f3dc9ea1b",
            100
          ],
          "playReferer": [
            "playerContent",
            "fcd5c4b5191f1b0c29ca4b831dafbcd4ffb25fcc4bdde99491d4264f3dc9ea1b",
            107
          ]
        }
      },
      "wexwencai-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiWenCai;",
        "methods": {
          "<init>": [
            "<init>",
            "fab58e2914a2d5342f10994ab52c6d5a78dd8f08af2c7d991079939646dcc2b1"
          ],
          "homeContent": [
            "homeContent",
            "da9514992985fc3ab8774b6249260175fcbabe762ca582198fcecb41b7d0745d"
          ],
          "categoryContent": [
            "categoryContent",
            "432bd19f105600cd612ce86749b3c9e8a9f2bf75d476d2957051ce7f7c3e5d82"
          ],
          "detailContent": [
            "detailContent",
            "72d09fdb4c81c2a43c53c578e8ca5a10f2436a784293af1018bbf6dfc810d5bb"
          ],
          "playerContent": [
            "playerContent",
            "aed7b1eef214251b68194c5aa0086c6873130a6137ba6ae52fd901ae81ef6e51"
          ],
          "searchContent": [
            "searchContent",
            "928680a988cf4683619d2486987d8dcfb5ac9088c3079564d2d597e231149929"
          ]
        },
        "literals": {
          "defaultHost": [
            "b",
            "0f6029a87d98385e6ca65df0bc386d45b1d1eddb0ab2ed63d5451c73d763130b",
            145
          ],
          "signKeyPrefix": [
            "b",
            "0f6029a87d98385e6ca65df0bc386d45b1d1eddb0ab2ed63d5451c73d763130b",
            107
          ],
          "userAgent": [
            "b",
            "0f6029a87d98385e6ca65df0bc386d45b1d1eddb0ab2ed63d5451c73d763130b",
            174
          ],
          "referer": [
            "b",
            "0f6029a87d98385e6ca65df0bc386d45b1d1eddb0ab2ed63d5451c73d763130b",
            211
          ]
        }
      },
      "wexfengye-v1": {
        "cls": "Lcom/github/catvod/spider/WexFengYe4K;",
        "methods": {
          "<clinit>": [
            "<clinit>",
            "d4dd7f3937f8ded5aa4d7b98e817d3b14406f6302d0426d20409331e5b3c8873"
          ],
          "<init>": [
            "<init>",
            "7fa07ed42114c763e6ef0f6ea5156efec2f836afb5ac6289689f9cd9a6cc33cc"
          ],
          "homeContent": [
            "homeContent",
            "42549001b7c007d89c00de786787414cf75889da8e88aef0e33f3c05bf1eba21"
          ],
          "categoryContent": [
            "categoryContent",
            "8a1a9683c781e17f7e223d8d7dffa3305665f8bcaefc07ec00e1714fa5ba1c93"
          ],
          "detailContent": [
            "detailContent",
            "7f11a42e9e5138b77f42301c2900c05b32c8dd3ec291accf3b6742944f52b5fb"
          ],
          "playerContent": [
            "playerContent",
            "6d82e23979dbb52a9f73d174e2780de90e780511271510dfe33d99321589a74e"
          ],
          "searchContent": [
            "searchContent",
            "996a8b435c747163b0d7c8431ca51933179083d89e97beee71c01c0474f51bed"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "7fa07ed42114c763e6ef0f6ea5156efec2f836afb5ac6289689f9cd9a6cc33cc",
            3
          ],
          "host0": [
            "<clinit>",
            "d4dd7f3937f8ded5aa4d7b98e817d3b14406f6302d0426d20409331e5b3c8873",
            0
          ],
          "host1": [
            "<clinit>",
            "d4dd7f3937f8ded5aa4d7b98e817d3b14406f6302d0426d20409331e5b3c8873",
            2
          ],
          "playerJdBase": [
            "<clinit>",
            "d4dd7f3937f8ded5aa4d7b98e817d3b14406f6302d0426d20409331e5b3c8873",
            50
          ],
          "playerCoBase": [
            "<clinit>",
            "d4dd7f3937f8ded5aa4d7b98e817d3b14406f6302d0426d20409331e5b3c8873",
            62
          ],
          "userAgent": [
            "d",
            "673a1f29557dfac8fece9dbb91337816b25bb578713870bb28354083dd457534",
            2
          ],
          "picProxyPrefix": [
            "f",
            "c11c9aef77e06bd218660e94851a758910c88102954623fb01a62091bad4fefc",
            116
          ]
        }
      },
      "wexjianpian-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiJianPian;",
        "methods": {
          "<init>": [
            "<init>",
            "47b8e8bc6861df0f99c928d86e131e9fe0e5f1fd1e8e59a6e74494a81ed84d67"
          ],
          "init": [
            "init",
            "65490dcb4856044c4c2f3822d5a7bcb16aaead25ed617e5bf09cc976350e33cf"
          ],
          "homeContent": [
            "homeContent",
            "01b90c8df6fff486935bc16c7a21a303f01f1328824ea87a62dae519a31b5089"
          ],
          "homeVideoContent": [
            "homeVideoContent",
            "79bd4e7be17eb632fb7a8d6286f5ee6c34f9833595ba6c47f604d066c0537a29"
          ],
          "categoryContent": [
            "categoryContent",
            "b0a34e04976b5255e5d7c606a903c2216b09900f08e19da2d6f1b7aef34320ad"
          ],
          "detailContent": [
            "detailContent",
            "3450d38cfe67a8b547b3381e6465e81c9bcb9ff020722644af1c823fad065066"
          ],
          "playerContent": [
            "playerContent",
            "02ba84b38d0f7f0c076ff700002e686ada0b62380e4861075e57702d7c41f856"
          ],
          "searchContent": [
            "searchContent",
            "d7df7829fe4e3a989c0b5fced99f5f2a62aaf73e6a2244a5895c1119b9329299"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "47b8e8bc6861df0f99c928d86e131e9fe0e5f1fd1e8e59a6e74494a81ed84d67",
            3
          ],
          "alidnsUrl": [
            "init",
            "65490dcb4856044c4c2f3822d5a7bcb16aaead25ed617e5bf09cc976350e33cf",
            5
          ],
          "hostPrefix": [
            "init",
            "65490dcb4856044c4c2f3822d5a7bcb16aaead25ed617e5bf09cc976350e33cf",
            91
          ],
          "userAgent": [
            "a",
            "1fb6664410276b2b1ee93b97f802e90e77a9061c1cf4b1fbff96a1ea023ed1e6",
            2
          ]
        }
      },
      "wexjuxiafan-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiJuXiaFan;",
        "methods": {
          "<clinit>": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba"
          ],
          "<init>": [
            "<init>",
            "df576a8e8c8e4186fc7bdc6daa2a0c627fde1313f59fef75f24cd0af12822195"
          ],
          "init": [
            "init",
            "0d0c99d5f86615a67dbf66d8cf9b3677ae5e401596055e65b63b8af90740455f"
          ],
          "homeContent": [
            "homeContent",
            "fdaa90d358027d54c28a7ae122e67144f908a06056950691a8d000181e33a1dc"
          ],
          "categoryContent": [
            "categoryContent",
            "c701adc77a20fd06e01ba2f6a6562f608f3116f49fdf7d15165270aaa4fdf641"
          ],
          "detailContent": [
            "detailContent",
            "5902365c9f7c1246ac73310649ffccabcaed065d4166c877ed2c70bd59bc1a5b"
          ],
          "playerContent": [
            "playerContent",
            "3d7885b6d13ec61cae5d7670825eb221ec441702b967b71192e5286a960e6c5f"
          ],
          "searchContent": [
            "searchContent",
            "0c819ffdd2522c02ba84bead857b147386f5d8e02ca8726c0fbc2f80111d3e1d"
          ]
        },
        "literals": {
          "defaultHost": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            0
          ],
          "host1": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            2
          ],
          "host2": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            4
          ],
          "host3": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            6
          ],
          "host4": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            8
          ],
          "host5": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            10
          ],
          "host6": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            12
          ],
          "host7": [
            "<clinit>",
            "34837a1ca9af5cd266c9e119e0dce1b885acfedb4e7d102dcc43d0c00ee285ba",
            14
          ],
          "aesKey": [
            "b",
            "73a9f72085b9ddbdda783ec10306ac3c7ca216c5db5d1acaa6e70b4d2e556775",
            10
          ],
          "userAgent": [
            "l",
            "6cd41cb54d0a3e242bb8721c74818e34ea98868882f34b646336d9de53ffaf2e",
            148
          ]
        }
      },
      "wexrebo-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiReBo;",
        "methods": {
          "<init>": [
            "<init>",
            "1b754a658a9eabd37b5457bd8f39499657cdc5f20a418e4b6f13312bd7597768"
          ],
          "homeContent": [
            "homeContent",
            "426b36de973da2d955198198b12875c5d9d901e922aa0acd26e8232234a1489d"
          ],
          "categoryContent": [
            "categoryContent",
            "58bb3d0d157635fa3318c5dbef4e8b239f75f160f22a7b11d94c35fed96c79e6"
          ],
          "detailContent": [
            "detailContent",
            "72ae1a9178b818626de0f3d7f7c1fbdbdafda67be088a756ea11c08339043d83"
          ],
          "playerContent": [
            "playerContent",
            "180006d77986e9bdec9a5d091b8d51e84b32746df4572cdd61a7595a4dfc5dd4"
          ],
          "searchContent": [
            "searchContent",
            "2f54ad2ac192f356a9fcfad3d4546a0b3693597cae080d94c665a67e47632d3b"
          ]
        },
        "literals": {
          "topTypeUrl": [
            "homeContent",
            "426b36de973da2d955198198b12875c5d9d901e922aa0acd26e8232234a1489d",
            45
          ],
          "typeSearchUrl": [
            "categoryContent",
            "58bb3d0d157635fa3318c5dbef4e8b239f75f160f22a7b11d94c35fed96c79e6",
            123
          ],
          "detailUrl": [
            "detailContent",
            "72ae1a9178b818626de0f3d7f7c1fbdbdafda67be088a756ea11c08339043d83",
            58
          ],
          "searchUrl": [
            "searchContent",
            "2f54ad2ac192f356a9fcfad3d4546a0b3693597cae080d94c665a67e47632d3b",
            49
          ],
          "signSecret": [
            "d",
            "cf17299a909f8c07417c22ee308973b0846336d0aee731472f7e0fc268b2185e",
            2
          ],
          "multipartType": [
            "a",
            "4efb3486a3df1a916290619c7d5739473cdfccf6529f88b54a8f8d3d7e85f8d6",
            2
          ],
          "apiUa": [
            "a",
            "4efb3486a3df1a916290619c7d5739473cdfccf6529f88b54a8f8d3d7e85f8d6",
            6
          ],
          "playUa": [
            "playerContent",
            "180006d77986e9bdec9a5d091b8d51e84b32746df4572cdd61a7595a4dfc5dd4",
            20
          ]
        }
      },
      "wexbobo-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiBoBo;",
        "methods": {
          "<init>": [
            "<init>",
            "289efd79d885c5ea1ecfba2a2f4d78a5facb85ee66e30c4c54240f6512d645bd"
          ],
          "init": [
            "init",
            "7cdd2457ca8f14a7dfe46c5496a1d8b5ce09fe1a0929e12673d0b10de58b3c37"
          ],
          "homeContent": [
            "homeContent",
            "5a3c3c03665a568d9381001679b1a293598d7d363cfc850437824097d062362d"
          ],
          "categoryContent": [
            "categoryContent",
            "61067f27c3de169b70742398bd66b91f53aa4e9fac18ee94240ee8a1f95ff6fc"
          ],
          "detailContent": [
            "detailContent",
            "92eb0294242f7a89f39eb13374f38a37bd25ad4466608f0fc9cccbd1dba16690"
          ],
          "playerContent": [
            "playerContent",
            "45669574e12c835685c7cea62332a1a1312991956a96fc67032923a1784a834e"
          ],
          "searchContent": [
            "searchContent",
            "26ff3b704fad621b8a164c8779897be30ab2f7b187fda0abd0877c1ad7b99495"
          ]
        },
        "literals": {
          "defaultHost": [
            "homeContent",
            "5a3c3c03665a568d9381001679b1a293598d7d363cfc850437824097d062362d",
            73
          ],
          "userAgent": [
            "e",
            "10af66f680ad89d70e280b007770c2fca27145ae2b6780ad6ac49f0d3fd53fe2",
            2
          ],
          "boboParsePath": [
            "init",
            "7cdd2457ca8f14a7dfe46c5496a1d8b5ce09fe1a0929e12673d0b10de58b3c37",
            2
          ],
          "parseUrlA": [
            "playerContent",
            "45669574e12c835685c7cea62332a1a1312991956a96fc67032923a1784a834e",
            146
          ],
          "parseUrlB": [
            "playerContent",
            "45669574e12c835685c7cea62332a1a1312991956a96fc67032923a1784a834e",
            192
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexikanbot-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiIkanBot;",
        "methods": {
          "<init>": [
            "<init>",
            "1b754a658a9eabd37b5457bd8f39499657cdc5f20a418e4b6f13312bd7597768"
          ],
          "homeContent": [
            "homeContent",
            "3160ef7289de11925d5568800518a402614656d760fbf4acccfe274f9d106cc4"
          ],
          "categoryContent": [
            "categoryContent",
            "5a0f2f7d70a1494d0fd146e4571169402a418b1c3b31ee10bdf7771c7b7699d3"
          ],
          "detailContent": [
            "detailContent",
            "8d80fc4c3af2483f9c45db0432a1cc5626f150a6fb8658589c75f519c701ed2c"
          ],
          "playerContent": [
            "playerContent",
            "fe05123b478e0c2034b7520ef3f15d5bbd0145e3455b170a01335deeed1b7191"
          ],
          "searchContent": [
            "searchContent",
            "629aa232ca1f299d19b09b91dab49f3f12f2c90e9535901c1b82009df63c669a"
          ]
        },
        "literals": {
          "defaultHost": [
            "homeContent",
            "3160ef7289de11925d5568800518a402614656d760fbf4acccfe274f9d106cc4",
            61
          ],
          "userAgent": [
            "a",
            "d71efc61847a4cf0fc6b3e88f7a2ca3e0ebfbb922af88e61ea8aecaae87a201e",
            2
          ]
        }
      },
      "wexyiys-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiYiYs;",
        "methods": {
          "<init>": [
            "<init>",
            "cd5bba12f360b46b55b2af75b2897f836238cd69761da5d986cd7240440d760e"
          ],
          "init": [
            "init",
            "25881ad50cdec7799510d2a231fe6efa7a9000c22676d65bf30e29f85993cf0c"
          ],
          "homeContent": [
            "homeContent",
            "16ac176cd9bf5f259f9d61fc68e06ffb84d73ff9e9ec645cb2155a850dd018bb"
          ],
          "categoryContent": [
            "categoryContent",
            "b56f196a9043907f327d95399edfd375ef31ec285191873db2d24d96ac967c66"
          ],
          "detailContent": [
            "detailContent",
            "7e661faa87c74e6e46d19b7e75a2236b750144538c3ef718ffc1925f31881956"
          ],
          "playerContent": [
            "playerContent",
            "5b22194642aba273194a0c3724aa30661e57c2a69bb3ed7a2de6277c417a7439"
          ],
          "searchContent": [
            "searchContent",
            "d55b467c9691dcf1742dedce0513d6ea3b83e08079323bfe9baab9e58c484c81"
          ]
        },
        "literals": {
          "appId": [
            "<init>",
            "cd5bba12f360b46b55b2af75b2897f836238cd69761da5d986cd7240440d760e",
            3
          ],
          "genKeyUrl": [
            "init",
            "25881ad50cdec7799510d2a231fe6efa7a9000c22676d65bf30e29f85993cf0c",
            66
          ],
          "rsaPublicKeyPem": [
            "init",
            "25881ad50cdec7799510d2a231fe6efa7a9000c22676d65bf30e29f85993cf0c",
            106
          ],
          "typeListUrl": [
            "homeContent",
            "16ac176cd9bf5f259f9d61fc68e06ffb84d73ff9e9ec645cb2155a850dd018bb",
            30
          ],
          "vodListUrl": [
            "categoryContent",
            "b56f196a9043907f327d95399edfd375ef31ec285191873db2d24d96ac967c66",
            181
          ],
          "vodInfoUrl": [
            "detailContent",
            "7e661faa87c74e6e46d19b7e75a2236b750144538c3ef718ffc1925f31881956",
            75
          ],
          "playUrlApi": [
            "playerContent",
            "5b22194642aba273194a0c3724aa30661e57c2a69bb3ed7a2de6277c417a7439",
            121
          ],
          "searchUrlApi": [
            "searchContent",
            "d55b467c9691dcf1742dedce0513d6ea3b83e08079323bfe9baab9e58c484c81",
            63
          ],
          "apiUa": [
            "c",
            "37f36762adecf92185040134e353c8292d21d25faa5f23d9ac15e850fb4f5edd",
            2
          ],
          "playUa": [
            "playerContent",
            "5b22194642aba273194a0c3724aa30661e57c2a69bb3ed7a2de6277c417a7439",
            32
          ]
        }
      },
      "wexhanxiaoquan-v1": {
        "cls": "Lcom/github/catvod/spider/WexAiHanXiaoQuan;",
        "methods": {
          "<init>": [
            "<init>",
            "8721a4bf6e8dc1226fc779cfed7c59f36894aba12df47504e6fbbd0044758925"
          ],
          "init": [
            "init",
            "92d33b3fa2f204dd0ab6459b3beb911ca09d8a42590b9d680a499ed60f3a43bd"
          ],
          "homeContent": [
            "homeContent",
            "f63a547e2d1c6f104b8886efefe32e982bedf63d0c09dbaae2aa1115ba2e155f"
          ],
          "categoryContent": [
            "categoryContent",
            "760dce119f1100037200c4c389e6d743c9c877b12e9b41bf94c413c6a79f06f4"
          ],
          "detailContent": [
            "detailContent",
            "f035d2e86f21bb1bde9dd02b5c4e4f8d18e5d2544778dc43f1f53f1d37328602"
          ],
          "playerContent": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0"
          ],
          "proxy": [
            "proxy",
            "551d0452dc5b581770e72e33512691de929b2ff9a7d0b67247c8e437d55c6f55"
          ],
          "searchContent": [
            "searchContent",
            "6c3825539f832b90f2d3437c222b72f3d42e49227e26b68d48c4481f28553c8d"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "8721a4bf6e8dc1226fc779cfed7c59f36894aba12df47504e6fbbd0044758925",
            10
          ],
          "aesIvDefault": [
            "d",
            "62a3da2e59b2b92855efd1e6f13b21500b8f95f9bfcb6940b23962cc48196317",
            58
          ],
          "signSaltA": [
            "h",
            "3df2408c38bfbb3a69e002c09675f02ca960ec605c39c935fdc74175616a30aa",
            234
          ],
          "signSaltB": [
            "h",
            "3df2408c38bfbb3a69e002c09675f02ca960ec605c39c935fdc74175616a30aa",
            236
          ],
          "apiUa": [
            "h",
            "3df2408c38bfbb3a69e002c09675f02ca960ec605c39c935fdc74175616a30aa",
            281
          ],
          "appPkg": [
            "h",
            "3df2408c38bfbb3a69e002c09675f02ca960ec605c39c935fdc74175616a30aa",
            203
          ],
          "appVer": [
            "h",
            "3df2408c38bfbb3a69e002c09675f02ca960ec605c39c935fdc74175616a30aa",
            249
          ],
          "appVc": [
            "h",
            "3df2408c38bfbb3a69e002c09675f02ca960ec605c39c935fdc74175616a30aa",
            288
          ],
          "rewardAps": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0",
            304
          ],
          "rslvTail": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0",
            558
          ],
          "decodeKeyA": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0",
            838
          ],
          "decodeKeyB": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0",
            840
          ],
          "decodeKeyC": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0",
            851
          ],
          "picCdnHost": [
            "g",
            "db5a61a067bdb7430a3f23508caaaf04c18cdece9cf39c1bf881ad00b1269ca8",
            61
          ],
          "m3u8CdnBase": [
            "proxy",
            "551d0452dc5b581770e72e33512691de929b2ff9a7d0b67247c8e437d55c6f55",
            204
          ],
          "playUa": [
            "playerContent",
            "db063639a679dec76afa6d42ed0620a821549e3bbe573f0c512b135d470296c0",
            1519
          ]
        }
      },
      "wexduoduo-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewDuoDuo;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "233e7320be3cf7c92b16918be362ee667bddda2d0c7328a3e4a69f19288fd9d4"
          ],
          "defaultSite": [
            "g",
            "4ca45ad87fbecfaa396c02fc55b5eab1c1c9ff6728a0abe96da59954e7fccc6b"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "233e7320be3cf7c92b16918be362ee667bddda2d0c7328a3e4a69f19288fd9d4",
            0
          ],
          "defaultHost": [
            "g",
            "4ca45ad87fbecfaa396c02fc55b5eab1c1c9ff6728a0abe96da59954e7fccc6b",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexhuban-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewHuBan;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "6505e9f21f26dee82800f59983852783dc5a450d11e490b9a7446ad2ea463213"
          ],
          "defaultSite": [
            "g",
            "cddf5ee8313f907926911a645d8f5d2900be083bd076bc2af9d07fe6f48aaa4e"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "6505e9f21f26dee82800f59983852783dc5a450d11e490b9a7446ad2ea463213",
            0
          ],
          "defaultHost": [
            "g",
            "cddf5ee8313f907926911a645d8f5d2900be083bd076bc2af9d07fe6f48aaa4e",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexkuaiying-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewKuaiYing;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "430653c18984ee6111a41c07b4002a1243723491b9a62e7ee60fd23f287ba528"
          ],
          "defaultSite": [
            "g",
            "8114923f681146e09e440bc7398bce0fc2001deb5fbf7b32ff1541a630f63459"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "430653c18984ee6111a41c07b4002a1243723491b9a62e7ee60fd23f287ba528",
            0
          ],
          "defaultHost": [
            "g",
            "8114923f681146e09e440bc7398bce0fc2001deb5fbf7b32ff1541a630f63459",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexlabi-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewLaBi;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "768fc5b2bab63ddb39071114109e1261d0f511368f57fcf6c0611cb5b09ce80f"
          ],
          "defaultSite": [
            "g",
            "e7395f0d64935ca92c09ab620c09c3a4788915ce385f39faa4a7fde937cd7427"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "768fc5b2bab63ddb39071114109e1261d0f511368f57fcf6c0611cb5b09ce80f",
            0
          ],
          "defaultHost": [
            "g",
            "e7395f0d64935ca92c09ab620c09c3a4788915ce385f39faa4a7fde937cd7427",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexmuou-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewMuOu;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "809961ec7d9a18c89ddd5277f8a3e16a98a86b5ab05ed02a85e973d559f2045d"
          ],
          "defaultSite": [
            "g",
            "978d62627e6acd5b6189658d4f6c45781b699b9f31927707ce6894a3dcce9a31"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "809961ec7d9a18c89ddd5277f8a3e16a98a86b5ab05ed02a85e973d559f2045d",
            0
          ],
          "defaultHost": [
            "g",
            "978d62627e6acd5b6189658d4f6c45781b699b9f31927707ce6894a3dcce9a31",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexshandian-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewShanDian;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "b6b637ec0274cd938fb914314991ae607c4c319f733a067e1472b3048fcccb7d"
          ],
          "defaultSite": [
            "g",
            "46320da83b507035d30375665a7ff76a877ce5d5a52b32959e6bb9baa25798ff"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "b6b637ec0274cd938fb914314991ae607c4c319f733a067e1472b3048fcccb7d",
            0
          ],
          "defaultHost": [
            "g",
            "46320da83b507035d30375665a7ff76a877ce5d5a52b32959e6bb9baa25798ff",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexxiaopan-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewXiaoPan;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "1924878f65cbbc7c8a0c88cf71ba2218c402cfba1a254081a298cdc7b414f658"
          ],
          "defaultSite": [
            "g",
            "eb3c97f338d338c2c41b2aba38350b87111d5ad8e1ab6611fc4708639f099f1b"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "1924878f65cbbc7c8a0c88cf71ba2218c402cfba1a254081a298cdc7b414f658",
            0
          ],
          "defaultHost": [
            "g",
            "eb3c97f338d338c2c41b2aba38350b87111d5ad8e1ab6611fc4708639f099f1b",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexzhizhen-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewZhiZhen;",
        "methods": {
          "<init>": [
            "<init>",
            "62503ea13c9dcb3075d42a6628514c1057ffee66700f6be8ea0e339bf74634a0"
          ],
          "siteKey": [
            "e",
            "9d82f596aa0e87d647ac22b6b8d4b39fe9cdf3668263c1416fe9f86381902af8"
          ],
          "defaultSite": [
            "g",
            "59fc66e2f73cc7902a51f979aa1e88accad7fa21d49de4ceb938ffd8ad014e2c"
          ]
        },
        "extraMethods": [
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "homeContent",
            "38551bdf76b66b808d4b21d581f2f995788d9a956a7e8571c5a53348666e2639"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "categoryContent",
            "de0d9540aa660dff919795bcc6d5000873afe0773c1a88a2935029a011d32be5"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "detailContent",
            "00e91a212b2430c429e65045324471c56b73f3e25fbeef98caa3494c0069874d"
          ],
          [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "searchContent",
            "6f33dba0e9694a0ccb9e2370a2f73b64fd7ed5c78276381e34c7c077e2124f6d"
          ]
        ],
        "literals": {
          "siteKey": [
            "e",
            "9d82f596aa0e87d647ac22b6b8d4b39fe9cdf3668263c1416fe9f86381902af8",
            0
          ],
          "defaultHost": [
            "g",
            "59fc66e2f73cc7902a51f979aa1e88accad7fa21d49de4ceb938ffd8ad014e2c",
            0
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ],
          "userAgent": [
            "Lcom/github/catvod/spider/AiMacPanSite;",
            "h",
            "dafe39d3196b732785bc59fcdc54adc3ed40cdc4b510d49f97a173bbea9a037c",
            7
          ]
        }
      },
      "wexwogg-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewWogg;",
        "methods": {
          "<init>": [
            "<init>",
            "4d171f67fee2ef882cba45b6368e09c564254f79e3afb7f4a60a731ab9b8262e"
          ],
          "init": [
            "init",
            "af0bb72c0831832e2a1cd2ea485d36877722677d83829e8af53aa10f3607d10c"
          ],
          "homeContent": [
            "homeContent",
            "5a705012766d3bdf47d2560850ea728b3827a6999b87dbe45206122883118d14"
          ],
          "categoryContent": [
            "categoryContent",
            "99ddec431e98584973c55dcd718aebe947e61186f9d005d06dbe8aaa4a34835b"
          ],
          "detailContent": [
            "detailContent",
            "72001565d73a7a2e91e02fe39d40bba110dc0f3868ef9ff114c4487dafbd4f4c"
          ],
          "searchContent": [
            "searchContent",
            "e1ad6b89d19d8d56b5cceeb16f0bae01b8a1fa358ddf3e8e6663a1ad02d0f86c"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "4d171f67fee2ef882cba45b6368e09c564254f79e3afb7f4a60a731ab9b8262e",
            3
          ],
          "siteKey": [
            "init",
            "af0bb72c0831832e2a1cd2ea485d36877722677d83829e8af53aa10f3607d10c",
            0
          ],
          "userAgent": [
            "a",
            "d71efc61847a4cf0fc6b3e88f7a2ca3e0ebfbb922af88e61ea8aecaae87a201e",
            2
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexhuajuan-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewHuaJuan;",
        "methods": {
          "<init>": [
            "<init>",
            "35853f115e28db6ae13afa4c176b2dc03f91285724a03e94e4be86fe05f53495"
          ],
          "homeContent": [
            "homeContent",
            "1c52768bd69ff8d46a834e83e9e0a6765c6a8437499c88f0dd1b982b79de4fcf"
          ],
          "categoryContent": [
            "categoryContent",
            "069fe134fdb70b7ed257ba97b98bf3f0fe273708c119c1ec026a8b5612a24f2e"
          ],
          "detailContent": [
            "detailContent",
            "9afffd53ec3076023098473c34206b8c22fa2cbbdc169e48f2161dd77f0c1cd7"
          ],
          "searchContent": [
            "searchContent",
            "09a649ea01368ba7f699209f3dbe0a3539fa41204cfbf9873af43887aaea1fbd"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "35853f115e28db6ae13afa4c176b2dc03f91285724a03e94e4be86fe05f53495",
            15
          ],
          "siteKey": [
            "o",
            "75481d546aa42109dd9c780e8b2e0590ea7e8c886bb23c83a2164e4cf8532df7",
            7
          ],
          "userAgent": [
            "h",
            "c46d565b2b8a2e5d9f7fe277387389a2427c09aeeb293f51fd995351ff711728",
            2
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexjutou-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewJuTou;",
        "methods": {
          "<init>": [
            "<init>",
            "2eeaa433ab139f70a758fd56e132e9a7ac1a790caea88cc8e382b7853f01be14"
          ],
          "init": [
            "init",
            "14d56546b4c52e4922ffaf3068603e2ef9bb20652326d46deca3eceef0f92a9e"
          ],
          "homeContent": [
            "homeContent",
            "f0e52046b52b88304fe491b51eb57d469bff4b9ba9b14de117a9ef0e5fa31989"
          ],
          "categoryContent": [
            "categoryContent",
            "4498ca9085d8674732ea3e388a1669a81e1a88a77308c588de7c9c9160557ac4"
          ],
          "detailContent": [
            "detailContent",
            "08cb634dc14552e9da7793dd3f31a31c509c74c238effb82ef98a6cfde326432"
          ],
          "searchContent": [
            "searchContent",
            "236008a7b21e2b140e1620b404cfd4ae28304f9de722680b023b61f7f9a9f828"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "2eeaa433ab139f70a758fd56e132e9a7ac1a790caea88cc8e382b7853f01be14",
            15
          ],
          "siteKey": [
            "init",
            "14d56546b4c52e4922ffaf3068603e2ef9bb20652326d46deca3eceef0f92a9e",
            0
          ],
          "userAgent": [
            "a",
            "31f51aeab132d4125c84dffb36037b119a4b7ba1fb217e67169579cd8d7776a0",
            2
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexzhinan-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewZhiNan4K;",
        "methods": {
          "<init>": [
            "<init>",
            "d859e229be60a834ce2e9e4ce6f72f7b1124ae3b4aa62050f6a441f51b249650"
          ],
          "homeContent": [
            "homeContent",
            "947f040da287a2bcc81ed7a2613a9d6a51f48a63ae36c26f9dd2f7acf4369043"
          ],
          "categoryContent": [
            "categoryContent",
            "41aa61c6e0755b7c0ce022492cf0b24e513ab99f87cf7638e480896416358681"
          ],
          "detailContent": [
            "detailContent",
            "ab7d779aa963506ae357776a455645841a1fca0cb6935f588c3d000dae9d2726"
          ],
          "searchContent": [
            "searchContent",
            "c8208bc9547270113111a559f555a4d5c590620f274fff63ab23ed4384e77949"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "d859e229be60a834ce2e9e4ce6f72f7b1124ae3b4aa62050f6a441f51b249650",
            15
          ],
          "userAgent": [
            "a",
            "0f72518dac4b2d6bbcff70d91182843824afeed2eff3061a204b85fbbc706354",
            7
          ]
        }
      },
      "wexwoniu-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewWoNiu4K;",
        "methods": {
          "<init>": [
            "<init>",
            "6cad3bbee1df0b9f108dd8719f4738c7295db6eacebaef29b0781a5c0c3a709d"
          ],
          "homeContent": [
            "homeContent",
            "4f54fd1fe2274abb8f956ce5eccd7afbcf9b6f71cd489131a09cc523f486c2ff"
          ],
          "categoryContent": [
            "categoryContent",
            "904789ae236dbf8d41e88f08f7c53480e1de83e7a9faab63ff43ed5d85465e8e"
          ],
          "detailContent": [
            "detailContent",
            "c26ce878f7271aea9d8d5987dfa29bfbebf90d39560909e9574628bc7cebf931"
          ],
          "searchContent": [
            "searchContent",
            "540ccda9e96ae86cbbab75214ed29137af80c85c8a3aec447eccf01f274957ea"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "6cad3bbee1df0b9f108dd8719f4738c7295db6eacebaef29b0781a5c0c3a709d",
            15
          ],
          "siteKey": [
            "l",
            "0785441507650c3b75c0a9e038f2b825bfcdcad2ce4303bc5b49e520d8e5d6b7",
            8
          ],
          "userAgent": [
            "g",
            "fafb15e80ded4b8c78e0ccedc5777b711f547970170d0853d4308ea85014fdb8",
            2
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexpianku-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewPianKu;",
        "methods": {
          "<init>": [
            "<init>",
            "0669584630f106e3f69724aee2f90239d9d7bcbdce0d7541976cb11d92ddb283"
          ],
          "homeContent": [
            "homeContent",
            "3c0d0b5fc2850914e928b0d55e5b43fce204ed36e73f036acd6a2432c1262465"
          ],
          "categoryContent": [
            "categoryContent",
            "8cdad36b5957369890d679c0fb29f79e27b3a15b75fe597eccc5053180a3bd73"
          ],
          "detailContent": [
            "detailContent",
            "9c9cf5793d1c132c775f865211874e66ed39cb982396885157017cfa0061243b"
          ],
          "searchContent": [
            "searchContent",
            "61fd25fbdd657e8263a32b69d5414edab3b21c3511a68d85b563c4e661c21bf2"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "0669584630f106e3f69724aee2f90239d9d7bcbdce0d7541976cb11d92ddb283",
            15
          ],
          "siteKey": [
            "x",
            "90eef0ccea9075a41858093256930fe5a395d9ac0ef755a6e7bf4863abcf33b4",
            8
          ],
          "siteKeyAlt": [
            "x",
            "90eef0ccea9075a41858093256930fe5a395d9ac0ef755a6e7bf4863abcf33b4",
            17
          ],
          "userAgent": [
            "m",
            "16719824d38c382d8ba69efebb9170ce86ed8e8453bb174bd8a9bb8e0d340307",
            2
          ],
          "fetchApiPath": [
            "q",
            "f99bc143ce18556c2faf64233150da9ee841bf4530f6c552a4616881e543ce2c",
            292
          ],
          "openApiPath": [
            "detailContent",
            "9c9cf5793d1c132c775f865211874e66ed39cb982396885157017cfa0061243b",
            120
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexqiwei-v1": {
        "cls": "Lcom/github/catvod/spider/AiQwMkv;",
        "methods": {
          "<init>": [
            "<init>",
            "34028f9bd479c63187a56071c85e278621a97f5c19e269721962e0696215973d"
          ],
          "init": [
            "init",
            "abd89a494a5d083052bf6a0a07e8f29f4cab5dadb723123acd23404139595ddc"
          ],
          "homeContent": [
            "homeContent",
            "6195e54e650da680b2fe0dc6845bc84eb1518ba489cc05aeeab027e52cc1cb11"
          ],
          "categoryContent": [
            "categoryContent",
            "2ca17d978ce8f97657160517cb5fb642c318f25e49c53f1376798949067a078a"
          ],
          "detailContent": [
            "detailContent",
            "3186025e003c1203f8a9135042cdf6e4bf4c4de00636ff86f7ac35166cadc88a"
          ],
          "playerContent": [
            "playerContent",
            "ebdab1f4876b989ba0e546e8068989279ca7a39fc1586cd60031d78a5a4e6d15"
          ],
          "searchContent": [
            "searchContent",
            "0e39fa4ce5e5830a1a36b14a7c25f87959fd598aaf4c656235dcc0c99e58e4de"
          ]
        },
        "literals": {
          "defaultHost": [
            "<init>",
            "34028f9bd479c63187a56071c85e278621a97f5c19e269721962e0696215973d",
            15
          ],
          "siteKey": [
            "init",
            "abd89a494a5d083052bf6a0a07e8f29f4cab5dadb723123acd23404139595ddc",
            2
          ],
          "userAgent": [
            "k",
            "52fff6521b3f05f5ed5fba680a769d834bb978f418e104e6e9bc9b53d16938c1",
            2
          ]
        },
        "extraLiterals": {
          "apiTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            0
          ],
          "apiTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            2
          ],
          "apiTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            4
          ],
          "apiTxt3": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            6
          ],
          "itemTxt0": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            14
          ],
          "itemTxt1": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            16
          ],
          "itemTxt2": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "<clinit>",
            "76d7a20eeab39ffafafdcccbd93c40a535cf42e47a45f217dfbab9e36e7ba7d1",
            18
          ],
          "remoteAesKey": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            11
          ],
          "remoteAesIv": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "b",
            "72c4200e62bf43d3c8b03e68871881d51d12ad088edc31395c33568f7611ed49",
            13
          ],
          "mySiteSuffix": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "p",
            "60e4695101c7cbafadb3638da466850468f49507e4a7d2c9521706ce2a1a0bba",
            60
          ],
          "remoteUa": [
            "Lcom/github/catvod/spider/merge/b0/b;",
            "j",
            "c42c469777871dd610c51810074b57b299823e8858bbf6dbea70ad70191a0bfa",
            7
          ]
        }
      },
      "wexyidong-v1": {
        "cls": "Lcom/github/catvod/spider/AiNewYiDong4K;",
        "methods": {
          "<init>": [
            "<init>",
            "09645215f624e7643c8000eeb9818969e2d2717316967c72e8e9aee1cf92d40c"
          ],
          "homeContent": [
            "homeContent",
            "f67338d3f826f31fa579a1ab2636c6d3d94fc0707a597f3de8ed4be2e35daaa3"
          ],
          "categoryContent": [
            "categoryContent",
            "d794406982e18acd4bb79e7149b830ef656cb36a81c2978a72eaefce63861819"
          ],
          "detailContent": [
            "detailContent",
            "82966ffa1c3096a9a2251323171bf1ae2c7b8d3cc98fc2ae6370cad6c7cc87a0"
          ],
          "searchContent": [
            "searchContent",
            "aab6c2e37621cbcda02b308a5e44db2fb9eeed6d1a62231c754c4d61ad93597f"
          ]
        },
        "literals": {
          "apiBase": [
            "c",
            "8a99bf43a703bb059182292d30b59f93e3f373f9da9c76b0d5dd3678f2a27574",
            2
          ],
          "originUrl": [
            "c",
            "8a99bf43a703bb059182292d30b59f93e3f373f9da9c76b0d5dd3678f2a27574",
            33
          ],
          "refererUrl": [
            "c",
            "8a99bf43a703bb059182292d30b59f93e3f373f9da9c76b0d5dd3678f2a27574",
            40
          ],
          "userAgent": [
            "c",
            "8a99bf43a703bb059182292d30b59f93e3f373f9da9c76b0d5dd3678f2a27574",
            18
          ]
        }
      },
      "wexaipanso-v1": {
        "cls": "Lcom/github/catvod/spider/SoAiAiPanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "ad5b42817082bd20e40aea9bc5d20e79c460e54e07d2f4fff70998d29c13eaa1"
          ],
          "detailContent": [
            "detailContent",
            "853a1083c9d875a3b477959056a90ccc271c14837068122e8b26492b7a04003d"
          ],
          "searchContent": [
            "searchContent",
            "cba89e38ed5c45cdda5dd901c23e06e11502fcb840cc0bad4f595e52915f1c0c"
          ]
        },
        "literals": {
          "defaultHost": [
            "detailContent",
            "853a1083c9d875a3b477959056a90ccc271c14837068122e8b26492b7a04003d",
            72
          ],
          "cvUrlPrefix": [
            "detailContent",
            "853a1083c9d875a3b477959056a90ccc271c14837068122e8b26492b7a04003d",
            66
          ],
          "searchUrlPrefix": [
            "searchContent",
            "cba89e38ed5c45cdda5dd901c23e06e11502fcb840cc0bad4f595e52915f1c0c",
            24
          ],
          "userAgent": [
            "detailContent",
            "853a1083c9d875a3b477959056a90ccc271c14837068122e8b26492b7a04003d",
            85
          ]
        }
      },
      "wexhaiyin-v1": {
        "cls": "Lcom/github/catvod/spider/SoAiHaiYin;",
        "methods": {
          "<clinit>": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398"
          ],
          "<init>": [
            "<init>",
            "ad5b42817082bd20e40aea9bc5d20e79c460e54e07d2f4fff70998d29c13eaa1"
          ],
          "init": [
            "init",
            "6c1e87c78c8266785b86cf43c683c203dd2acf9e828638e3c6b981c6ff5a71e5"
          ],
          "detailContent": [
            "detailContent",
            "beba1422461d5e8e8d1edd8b4c6e4ceeeaf71d2bf304001a99204440a078f8e5"
          ],
          "searchContent": [
            "searchContent",
            "11e9b271642c78ebf6a1dad15980e31ace906aac907fa84f7b4f80b267cd5f92"
          ]
        },
        "literals": {
          "defaultHost": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398",
            6
          ],
          "site0": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398",
            0
          ],
          "site1": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398",
            2
          ],
          "site2": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398",
            4
          ],
          "site3": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398",
            8
          ],
          "site4": [
            "<clinit>",
            "d77b115481118abe40fb0c48549c442d297f6e398a8859171e2990b26a3c2398",
            10
          ],
          "searchApiPath": [
            "q",
            "dcd2a34f3bb7cc94f352724d2ad0bd10b3eb3af776f1511ae0db9572b5acb1ec",
            34
          ],
          "userAgent": [
            "q",
            "dcd2a34f3bb7cc94f352724d2ad0bd10b3eb3af776f1511ae0db9572b5acb1ec",
            59
          ]
        }
      },
      "wexquanpan-v1": {
        "cls": "Lcom/github/catvod/spider/SoAiQuanPan;",
        "methods": {
          "<init>": [
            "<init>",
            "259bb17a6e5d39c16f827bb8f441821b48d2422e608135ed568d58b99d787a4e"
          ],
          "detailContent": [
            "detailContent",
            "25bba66fd0714389a4ca9a2e4ec4cd70e0df4d8c0212abfa7aa0c965c0728b82"
          ],
          "searchContent": [
            "searchContent",
            "730d59e57abd125268cc07c0698fb0da6ed87f25de84fbef64afb8f58ad3e113"
          ]
        },
        "literals": {
          "defaultHost": [
            "w",
            "c1133d1a4e4de3329b26138dc2d269dffd183bf4f90d9b6d20ea963d80b2396e",
            21
          ],
          "refererUrl": [
            "w",
            "c1133d1a4e4de3329b26138dc2d269dffd183bf4f90d9b6d20ea963d80b2396e",
            14
          ],
          "tokenUrl": [
            "u",
            "e79876240d6e025303e319365600ded66f79b38b6e5e8e5e192312f192fe943e",
            25
          ],
          "searchApiUrl": [
            "B",
            "e48f9e25be72b7d8f968d308b3769fa7d1e460c9b73aaa70b92fe9cee35c053b",
            21
          ],
          "resourcesApiPrefix": [
            "s",
            "d23b67daf8e10119d088e2bb4b7bbb9414096cb30e2caa4ca4363bf21ab71852",
            6
          ],
          "userAgent": [
            "w",
            "c1133d1a4e4de3329b26138dc2d269dffd183bf4f90d9b6d20ea963d80b2396e",
            6
          ]
        }
      },
      "wexkaka-v1": {
        "cls": "Lcom/github/catvod/spider/SoKaKa;",
        "methods": {
          "<init>": [
            "<init>",
            "9f3bcc3bbee66f4514d4692b9347f2ab293ffc061bd85c6b650905853bcfdf58"
          ],
          "homeContent": [
            "homeContent",
            "359ff7f4479ee9f42ac19e99cf1c5f2463fd862c3cdaf8df6ceb55bb879672a3"
          ],
          "detailContent": [
            "detailContent",
            "fc4fdeb04877591b6ae886c334b7b9518304e6f6c3695f72c0e984d921888b68"
          ],
          "searchContent": [
            "searchContent",
            "e2264023437195c31088f0314861e85a787abe9e1f854711ed3f6270106bf4f4"
          ]
        },
        "literals": {
          "defaultHost": [
            "b",
            "efa4e6edbf989926eee63820e69249342d2a7b5e999e140e30abfb9e6b327440",
            25
          ],
          "searchApiPrefix": [
            "searchContent",
            "e2264023437195c31088f0314861e85a787abe9e1f854711ed3f6270106bf4f4",
            81
          ],
          "searchApiSuffix": [
            "searchContent",
            "e2264023437195c31088f0314861e85a787abe9e1f854711ed3f6270106bf4f4",
            83
          ],
          "washApiUrl": [
            "detailContent",
            "fc4fdeb04877591b6ae886c334b7b9518304e6f6c3695f72c0e984d921888b68",
            174
          ],
          "userAgent": [
            "b",
            "efa4e6edbf989926eee63820e69249342d2a7b5e999e140e30abfb9e6b327440",
            6
          ]
        }
      }
    }
  }
};

const fail = () => { throw Error('guard_artifact_invalid'); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

function unwrapWexGuard(bytes) {
  const table = new Uint8Array(256);
  const swap = { 2: 9, 9: 2, 4: 8, 8: 4 };
  for (let b = 0; b < 256; b++) {
    const s = swap[b] !== undefined ? swap[b] : b;
    const x = s ^ 0x5f;
    table[b] = ((x >>> 1) | ((x & 1) << 7)) & 0xff;
  }
  const out = Buffer.allocUnsafe(bytes.length);
  for (let i = 0; i < bytes.length; i++) out[i] = table[bytes[i]];
  return out;
}

function parseHttpOrigin(raw) {
  if (typeof raw !== 'string' || !raw) fail();
  const text = raw.trim();
  if (!text || text.length > 2048 || /[\x00-\x20\x7f\\]/.test(text)) fail();
  let url;
  try { url = new URL(text); } catch (_) { fail(); }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname || url.username || url.password) fail();
  return url.origin;
}

function decodeWexExtension(rawExt) {
  if (rawExt === undefined || rawExt === null) return '';
  if (typeof rawExt !== 'string' || Buffer.byteLength(rawExt) > 16 * 1024) fail();
  const trimmed = rawExt.trim();
  if (!trimmed) return '';
  if (trimmed.startsWith('{') || trimmed.startsWith('[') || /^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  if (/^[A-Za-z0-9+/=_-]{4,}$/.test(trimmed)) {
    let normalized = trimmed.replace(/-/g, '+').replace(/_/g, '/');
    while (normalized.length % 4 !== 0) normalized += '=';
    try {
      const plainUtf8 = decodeUtf8Fatal(Buffer.from(normalized, 'base64')).trim();
      if (plainUtf8 && (plainUtf8.startsWith('{') || plainUtf8.startsWith('[') || /^https?:\/\//i.test(plainUtf8))) {
        return plainUtf8;
      }
    } catch (_) {}
  }
  return trimmed;
}

function parseExtObject(extText) {
  if (!extText) return {};
  if (extText.startsWith('{')) {
    try {
      const parsed = JSON.parse(extText);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
    } catch (_) { fail(); }
  }
  return {};
}

function resolveOrigin(extracted, extText, extObj) {
  const candidates = [];
  for (const key of ['host', 'url', 'site', 'siteUrl', 'api', 'crypto']) {
    if (typeof extObj[key] === 'string' && /^https?:\/\//i.test(extObj[key].trim())) {
      candidates.push(extObj[key].trim());
    }
  }
  if (/^https?:\/\//i.test(extText)) {
    const first = extText.split(/[|,;\s]+/)[0];
    if (first) candidates.push(first);
  }
  for (const key of ['defaultHost', 'originUrl', 'apiBase', 'topTypeUrl', 'vodListUrl', 'apiTxt1', 'apiTxt0']) {
    if (typeof extracted[key] === 'string' && /^https?:\/\//i.test(extracted[key])) {
      candidates.push(extracted[key]);
    }
  }
  for (const c of candidates) {
    try { return parseHttpOrigin(c); } catch (_) {}
  }
  fail();
}

function extractWex(bytes, adapter, rawExtension) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX) fail();
  if (!WEX_ADAPTERS.includes(adapter)) fail();
  const profile = PROFILES[sha(bytes)];
  if (!profile) throw Error('guard_artifact_unsupported');
  const native = zipMember(bytes, 'assets/wexguard_v8.so');
  if (native.length !== profile.nativeSize || sha(native) !== profile.nativeSha) {
    throw Error('guard_artifact_integrity');
  }
  const spec = profile.spiders[adapter];
  if (!spec) throw Error('guard_artifact_unsupported');
  const extText = decodeWexExtension(rawExtension);
  const extObj = parseExtObject(extText);

  const budget = { bytes: 0, entries: 0 };
  const dex = new Dex(zipMember(unwrapWexGuard(zipMember(bytes, 'assets/wexshinidie.guard', budget)), 'classes.dex', budget));
  for (const [, [methodName, expectedHash]] of Object.entries(spec.methods)) {
    dex.reviewedCodeByHash(spec.cls, methodName, expectedHash);
  }
  if (Array.isArray(spec.extraMethods)) {
    for (const [clsName, methodName, expectedHash] of spec.extraMethods) {
      dex.reviewedCodeByHash(clsName, methodName, expectedHash);
    }
  }

  const extracted = {};
  if (spec.literals) {
    for (const [k, [methodName, expectedHash, unit]] of Object.entries(spec.literals)) {
      extracted[k] = dex.reviewedLiteralByHash(spec.cls, methodName, expectedHash, unit);
    }
  }
  if (spec.extraLiterals) {
    for (const [k, [clsName, methodName, expectedHash, unit]] of Object.entries(spec.extraLiterals)) {
      extracted[k] = dex.reviewedLiteralByHash(clsName, methodName, expectedHash, unit);
    }
  }

  const origin = resolveOrigin(extracted, extText, extObj);
  return {
    adapter,
    origin,
    extText,
    ext: extObj,
    ...extracted
  };
}

module.exports = { WEX_ADAPTERS, VOD_WEX_ADAPTERS, unwrapWexGuard, extractWex, decodeWexExtension };
