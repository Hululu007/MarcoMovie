// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
'use strict';
// Data-only interoperability for reviewed FTY Guard plugins: no native, DEX, or imported script execution.
const crypto = require('node:crypto');
const { zipMember, unwrapGuard, Dex, MAX } = require('./drpy-guard-extractor.cjs');
const { elfBytes, decodeShiftedExt, decodeUtf8Fatal } = require('./drpy-t4-extractor.cjs');

const FTY_ADAPTERS = Object.freeze([
  'jpys-v1', 'jpj-v1', 'nmyswv-v1', 'hmys-v1', 'app99-v1', 'appsx-v1', 'newcz-v1', 'libvio-v1', 'ygp-v1',
  'kanqiu-v1', 'doubao-v1', 'livegz-v1', 'alllive-v1', 'tingshu275-v1', 'yueting-v1',
  'seedhub-v1', 'szps-v1', 'ypanso-v1', 'bpanso-v1', 'kkss-v1', 'uuss-v1'
]);

const PROFILES = {
  "88e67402129e7db92669fb351397ecd4d09709e6c70b577f22a19cfb0ad5f204": {
    "nativeSha": "fac9e3937d9928e437ebff79bc5164df418a6adb212494ef21c273579b045dcb",
    "mask": 183,
    "spiders": {
      "jpys-v1": {
        "cls": "Lcom/github/catvod/spider/Jpys;",
        "methods": {
          "<init>": [
            "<init>",
            "1c21ac3233a5b01ae288f8501674b5c77cd13992b71a564c0242d1ceb478f1e6"
          ],
          "init": [
            "init",
            "3e9c9d59f67af8ff862e4579a0f5aab31a47897d6220350bc64d983abe06dc3a"
          ],
          "homeContent": [
            "homeContent",
            "6cf89acec81ea127529cc5c0535b45fcf13ba204a6c461e4f46b6fd36e4dd9e7"
          ],
          "categoryContent": [
            "categoryContent",
            "2a53469c41a09b456652eebb3ebe1389998f19680c075de472598fea2212c531"
          ],
          "detailContent": [
            "detailContent",
            "c02701c9d1d23185ed936b6f7d0509d60c6d8c94031ec0792a3af3110eabc5a1"
          ],
          "playerContent": [
            "playerContent",
            "398458150bcab2d156b61c78a42fd46edb45718d8a207a603174ffbb770c78f7"
          ],
          "searchContent": [
            "searchContent",
            "7bfd22d934894feef1a9d8aec93a46ca1b2aee8a01ddc60e5e4a84f25fa6b3e6"
          ]
        },
        "shortArray": [
          "74da13729a24ca298b964f847c1a87d3f957179ac1279a73cd73050e3bea6696",
          "short",
          10,
          1191
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            2157
          ],
          "signSuffix": [
            68,
            40,
            2454
          ],
          "userAgent": [
            670,
            102,
            3210
          ]
        }
      },
      "jpj-v1": {
        "cls": "Lcom/github/catvod/spider/JPJ;",
        "methods": {
          "<init>": [
            "<init>",
            "6ed4af95b3419eba2476956d05bcaef04d87a10c46123672dab296a757dfadcf"
          ],
          "init": [
            "init",
            "865d1eecd80a4d5bc1746bd83005f4bd56b5e091a0417509dfbeced04c53a515"
          ],
          "homeContent": [
            "homeContent",
            "dd349330b9fd1e389da947172b99c424734491e4ff516924595af8316c0c526b"
          ],
          "categoryContent": [
            "categoryContent",
            "ef0ad085a1ba3db82686aec2c6b65431d8753174580ffbcccb9db7b4a920b102"
          ],
          "detailContent": [
            "detailContent",
            "147e853f4a5c92c4021ddc271984fce2273e865bb05dd2f60dae229e58395bb5"
          ],
          "playerContent": [
            "playerContent",
            "61008f5e6e69d8992de0c847d93dbdcdfe631bcff907e00eae0d7e7c3787e622"
          ],
          "searchContent": [
            "searchContent",
            "f9e7e0efe6f63467260c531b85733f265bcdb544cad9bacc9f25ba99b75a96ef"
          ]
        },
        "shortArray": [
          "6cda4d874dbf280ed9d4129df897220344dd472403aa285d550574571d168700",
          "short",
          10,
          737
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            2038
          ],
          "alidnsUrl": [
            517,
            63,
            3078
          ],
          "fanPrefix": [
            592,
            15,
            2408
          ],
          "domainConfigPath": [
            607,
            37,
            809
          ],
          "userAgent": [
            34,
            247,
            1943
          ]
        }
      },
      "nmyswv-v1": {
        "cls": "Lcom/github/catvod/spider/Nmyswv;",
        "methods": {
          "<init>": [
            "<init>",
            "e5d2703cab0cb1a01ede65ec922b058e0b91a3cd13962be9cb76fe8fa7ae7dab"
          ],
          "init": [
            "init",
            "9c04f57f2a35cadbb91d50076afea67406f16b15777cfcf446ae769de9ba3088"
          ],
          "homeContent": [
            "homeContent",
            "6c16c8ff88a4b8efafe2a6033fcbb055d8ec6ae4f5e26f071a3c4898ded1d9da"
          ],
          "categoryContent": [
            "categoryContent",
            "04926b08543216ac8672298aef7b755ca882d7522b4fd08631dfa0302da16ac4"
          ],
          "detailContent": [
            "detailContent",
            "b89ad80cda52c998065944e80f79078ee5b8d7ff80f00350f077f450af2159f1"
          ],
          "playerContent": [
            "playerContent",
            "3cebb76dc001173d51e7727cfc02d5b1a50a121ea52a1bc956c49839ded9d744"
          ],
          "searchContent": [
            "searchContent",
            "227db30d70793dcc9b8629a82582144ee26b424b93838d890a9106b6139b720a"
          ]
        },
        "shortArray": [
          "83b2a2555d85b3050e7471de7b082e03341455195c9a803878094a5754d9fc45",
          "short",
          26,
          893
        ],
        "triples": {
          "defaultHost": [
            0,
            25,
            641
          ]
        }
      },
      "hmys-v1": {
        "cls": "Lcom/github/catvod/spider/Hmys;",
        "methods": {
          "<init>": [
            "<init>",
            "5f230399eef39ca555cc700d6e8082c985f1ba1ab9910eebacc37d335ef02e73"
          ],
          "init": [
            "init",
            "9c1be640a9bc4204d1cade35ac4c85ca363bc7c4bdb4c972c2f7376ad6c94b7c"
          ],
          "homeContent": [
            "homeContent",
            "68caf9c70fd9c777d88aaab89cbcd8c60cfbd38d5408b3cf8354a3a6972193f2"
          ],
          "categoryContent": [
            "categoryContent",
            "75e843d327c1130ee26f60df1d5eb9f0969419344630f3e23b74fe94ee079b27"
          ],
          "detailContent": [
            "detailContent",
            "8f0417af34c5e4274652a0307cbdd91c3ade2b72b5f4bf8166fa867bfd98071c"
          ],
          "playerContent": [
            "playerContent",
            "042fae57b564e7d8c26a3bdceadbcfc37571e30179a0c8f431bb9ff44b8cfaa3"
          ],
          "searchContent": [
            "searchContent",
            "6ff87e5696bb681b6ad9671364bdfa4884abcfb2d3bf54509a85ce7373118026"
          ]
        },
        "shortArray": [
          "79266cfa972e85235a0a454ed66d1c5bb01c6157c19f069bbb8ef4bc2ee2e5af",
          "short",
          10,
          2670
        ],
        "triples": {
          "aesKey": [
            0,
            32,
            876
          ],
          "aesIv1": [
            32,
            16,
            2497
          ],
          "aesIv2": [
            48,
            16,
            1047
          ],
          "defaultInitUrl": [
            64,
            36,
            1127
          ],
          "appName": [
            100,
            12,
            2523
          ],
          "channelCode": [
            112,
            9,
            764
          ],
          "packageName": [
            121,
            5,
            654
          ],
          "signKey": [
            126,
            16,
            2930
          ],
          "v2InitUrl": [
            519,
            41,
            994
          ],
          "v2Channel": [
            596,
            7,
            924
          ],
          "v2Pkg": [
            629,
            21,
            827
          ],
          "v2SignKey": [
            1174,
            32,
            502
          ],
          "uaOk412": [
            180,
            13,
            1362
          ],
          "uaOk49": [
            193,
            12,
            919
          ]
        }
      },
      "app99-v1": {
        "cls": "Lcom/github/catvod/spider/App99;",
        "methods": {
          "<init>": [
            "<init>",
            "7b836effb93e45f048adca67013c85a85e73c96232c0a3d7a60800573f930fa6"
          ],
          "init": [
            "init",
            "9aa1613e5592e60d1525d5900084ff7eb6a865157d587da791240cb39de92345"
          ],
          "homeContent": [
            "homeContent",
            "56c815908dff7d0e8bb23c70594b2fd3e3f08bb20f2aa1d82e51e63024d3354e"
          ],
          "categoryContent": [
            "categoryContent",
            "f34c213c5d8065d6479b914e5601cf44996470077e46f80954ac27c8c7576705"
          ],
          "detailContent": [
            "detailContent",
            "6d45f3dc01a54f8d58f185d1b1a3b53dc4ac0ed40846a0b5d65d97af3824cf82"
          ],
          "playerContent": [
            "playerContent",
            "a701fe1b0733684543509ec19e9bd447e7c8cb03d5f8eb96842af988d8df0da8"
          ],
          "searchContent": [
            "searchContent",
            "ab08be29ea7174e628743587e2f492a25156234594542393aa481164a30ac87a"
          ]
        },
        "shortArray": [
          "d3b3047fc25a78c2d43b757c60ec71eb11866c8f5428a898c29a01c31bfd6942",
          "short",
          10,
          1665
        ],
        "triples": {
          "defaultIv": [
            1227,
            16,
            2494
          ],
          "userAgent": [
            1290,
            115,
            2843
          ]
        }
      },
      "appsx-v1": {
        "cls": "Lcom/github/catvod/spider/AppSx;",
        "methods": {
          "<init>": [
            "<init>",
            "5cec289a224c2fa3f3ce36174380db26bfb576290783be814f4c0772bd51b13c"
          ],
          "init": [
            "init",
            "9f4cdfb59f7508b692412c8fb1b6ed297e608e51b690a226a11e5ec3b7c3cabc"
          ],
          "homeContent": [
            "homeContent",
            "d46e866dc20db1e2fde4f418385918967f7674b387614c0ef86d1a15c5cf3af9"
          ],
          "categoryContent": [
            "categoryContent",
            "52601d41de7177eec0127c178ae96a4249947f8a716539a7ed731a17ccf04e2f"
          ],
          "detailContent": [
            "detailContent",
            "6c37238b685a8903efe050cb019432773218ea645b2211d434bc83bcc9adf2f0"
          ],
          "playerContent": [
            "playerContent",
            "4da316ac0397169516166ba34f5d0292c8e9c87db32a8f30888ffe4539e965b9"
          ],
          "searchContent": [
            "searchContent",
            "4ab72d591ed48564728ac837b956f1ac9f05ccbc8c61621437525dc51d466c33"
          ]
        },
        "shortArray": [
          "62db4249b6900187267b9666543fb1c455156cf6e602938d8c0556b348ba9b2a",
          "short",
          10,
          2283
        ],
        "triples": {
          "defaultVerStr": [
            0,
            3,
            375
          ],
          "defaultPath": [
            3,
            19,
            392
          ],
          "qijiPath": [
            1795,
            20,
            3094
          ],
          "vodPath": [
            1815,
            9,
            947
          ],
          "uaOk310": [
            299,
            13,
            1815
          ],
          "uaOk314": [
            312,
            13,
            2525
          ]
        }
      },
      "newcz-v1": {
        "cls": "Lcom/github/catvod/spider/NewCz;",
        "methods": {
          "<init>": [
            "<init>",
            "788d0171dd06e3b7665c6ac5aad296b9ed48db4ad90825ff3c309c38abdffb7b"
          ],
          "init": [
            "init",
            "55636d9c4e1242aff19e6c3013f390f08f0e59bf7e43152471c844892d0d3a65"
          ],
          "homeContent": [
            "homeContent",
            "412ae95522029cef3beb98fd1d2312b1d9be0453b56a3f995281edc272fc3c1d"
          ],
          "categoryContent": [
            "categoryContent",
            "f5c15b6c38cfbe4b1696b615fe812e307253ecbedaf0721e03b89f3c031b3fee"
          ],
          "detailContent": [
            "detailContent",
            "1d03b600955896053e12047e80f5ce5556ee2c09f55aa2291d5dcbb9db21ae73"
          ],
          "playerContent": [
            "playerContent",
            "13c9c5067d50bf39b3d28503d222adcd3a4cb0f7bdc22af1bd0d3f805f5e8bb5"
          ],
          "searchContent": [
            "searchContent",
            "cb08c8bf8639482a4e7436b3469dcf9ecf5a7f06eeb579f7409130f5a15c49c9"
          ]
        },
        "shortArray": [
          "50dd3ac6cca975ca1a16a5aa39937fb6d68491455e4738c6ec01e54196fc37ab",
          "short",
          10,
          3150
        ],
        "triples": {
          "defaultHost": [
            0,
            21,
            1359
          ],
          "altHost": [
            21,
            20,
            2901
          ],
          "searchApi": [
            2528,
            46,
            1827
          ],
          "userAgent": [
            2647,
            116,
            1323
          ],
          "playUa": [
            2023,
            117,
            1115
          ],
          "czFunHost": [
            2242,
            25,
            861
          ],
          "czFunKey": [
            2267,
            16,
            2986
          ],
          "nowwonHost": [
            2191,
            24,
            377
          ],
          "pyHost": [
            2467,
            28,
            1678
          ]
        }
      },
      "libvio-v1": {
        "cls": "Lcom/github/catvod/spider/Libvio;",
        "methods": {
          "<init>": [
            "<init>",
            "8fde114c0b45f13f4f57b7e6b977ad8c56490406c0c8741cf3e610416b884f12"
          ],
          "init": [
            "init",
            "4689eacaf31a5ff708ee36135e9f9926d6c70023f7ec7c7c26d7c3a750dccb80"
          ],
          "homeContent": [
            "homeContent",
            "941cb9d147ab41e9b1d088c927a86dfd4aae9f6fe0299714b1aa37ff2bada201"
          ],
          "categoryContent": [
            "categoryContent",
            "b1fe929215226aead6f612e860639bcaf577393ff4a49d6ab54ac80d46db16ae"
          ],
          "detailContent": [
            "detailContent",
            "84df0e33344ed6e125d4802da779a3d3139157bc5c03bf5d0e938b7a4fa0143a"
          ],
          "playerContent": [
            "playerContent",
            "fd756d28d53540ab8cee084c3e6053de59d517c2295a0863bb4af6342d015f02"
          ],
          "searchContent": [
            "searchContent",
            "a2fcad89747b78785875f1d2eea269dc7bbe4aab4a8065c09ed36fd5e106f204"
          ]
        },
        "shortArray": [
          "a62ff5b97c053821756ab1849779e75101dee5e00731fc41518af01fe5b93320",
          "short",
          10,
          2012
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            2713
          ],
          "headersBlock": [
            210,
            560,
            457
          ],
          "playUa": [
            1606,
            102,
            1441
          ]
        }
      },
      "ygp-v1": {
        "cls": "Lcom/github/catvod/spider/YGP;",
        "methods": {
          "<init>": [
            "<init>",
            "905c00db42b847c02a19893f0d28bb659c4d5d7bff39ea2a1d98357aea054541"
          ],
          "init": [
            "init",
            "84863f6cd8ee1d8a2878b97647a6cd27a8f9746f18fc695de07195e06d6ceb30"
          ],
          "homeContent": [
            "homeContent",
            "b43a691c7f8405b55a8476bb5c811faa878581b70008aa1cd1352d9806c4d84e"
          ],
          "categoryContent": [
            "categoryContent",
            "e3a462a87adeee3dd941fbc726bb177e53cd0844a00e316c3717d42fcd12db5f"
          ],
          "detailContent": [
            "detailContent",
            "31c1a02f8c21f9f32d8480f5c3fdb9db219be0861695fb2273af61b8a33ed0f2"
          ],
          "playerContent": [
            "playerContent",
            "7dc21a9464d4f9c9955b49a4bbad5218d6bbfc86cae77740d9eec92bd2dea710"
          ],
          "searchContent": [
            "searchContent",
            "bf218b50ff4bd2b9c01a71e69380d569375ad92e9439d812c6410ee554e7fb2a"
          ]
        },
        "shortArray": [
          "29603665f8adb58aa05587f721fa1f40cecdcd89caf6c1af55e5bcfadbfccfda",
          "short",
          10,
          1268
        ],
        "triples": {
          "defaultHost": [
            4,
            21,
            3021
          ],
          "userAgent": [
            988,
            110,
            2811
          ]
        },
        "literals": {
          "filtersJson": [
            "init",
            "84863f6cd8ee1d8a2878b97647a6cd27a8f9746f18fc695de07195e06d6ceb30",
            5
          ]
        }
      },
      "kanqiu-v1": {
        "cls": "Lcom/github/catvod/spider/Kanqiu;",
        "methods": {
          "<init>": [
            "<init>",
            "ec418ff284ce4e6acc58aa4b527a35d6c4db8437af9e1122fb2f36d33a3da28f"
          ],
          "init": [
            "init",
            "5e198de9d44a70cf79d4d2b1fb49af78efcc30d1ae4542d43e7682eb6ea40400"
          ],
          "homeContent": [
            "homeContent",
            "3ad9c1c96ab734975db861fef3f1154b833ee2ad8bc998cad9dca87a0401b300"
          ],
          "categoryContent": [
            "categoryContent",
            "965f7a5e82f9acc2fda29043e4dc9c8f9baa8b5570244be680ebbad7148c039d"
          ],
          "detailContent": [
            "detailContent",
            "5933aa0a8e55d20aa666e86f2ffe360352be0bd487de429d442baa8cd71f211f"
          ],
          "playerContent": [
            "playerContent",
            "d81f8860aaa3ec05d79139b0a9887ffe9463644e92d53964fa1caae09775e1b5"
          ]
        },
        "shortArray": [
          "9fc266365ebd2b103a6c5adc916688026a28b031ff6acc4fe8a7420b60ea72d5",
          "short",
          26,
          1218
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            865
          ],
          "userAgent": [
            32,
            111,
            977
          ],
          "filtersJson": [
            367,
            767,
            2340
          ],
          "xxteaKey": [
            1191,
            24,
            2270
          ]
        }
      },
      "doubao-v1": {
        "cls": "Lcom/github/catvod/spider/Doubao;",
        "methods": {
          "<init>": [
            "<init>",
            "f78e4d760374353ba1112b0b87f83b47e755ae65458e827c1b6a63669218f5f4"
          ],
          "homeContent": [
            "homeContent",
            "8db9c24973ff99da6556611466a136406ccd9127cc14e277e8563e559a5f2a58"
          ],
          "categoryContent": [
            "categoryContent",
            "ffad1c627b81b11a3cea8a489dda46972341a8d463ec43c68eb8b92f97ff3353"
          ],
          "detailContent": [
            "detailContent",
            "9f93ffc569c3d6b669cfc16205acd19cb97e1d1316e89e1d86643f33e5096ae8"
          ],
          "playerContent": [
            "playerContent",
            "761b099df2b38991b8c249bdd20173f48a316ba01d979b1304dc9f27ef483840"
          ]
        },
        "shortArray": [
          "f73eae05cde25451ed3da10fe89e894519551775ecaac32d88f9f6bdb0172588",
          "short",
          10,
          1372
        ],
        "triples": {
          "defaultHost": [
            0,
            27,
            2178
          ],
          "scheduleUrl": [
            27,
            57,
            967
          ],
          "playbackUrl": [
            84,
            44,
            2841
          ],
          "userAgent": [
            128,
            111,
            2548
          ]
        }
      },
      "livegz-v1": {
        "cls": "Lcom/github/catvod/spider/LiveGz;",
        "methods": {
          "<init>": [
            "<init>",
            "08df0e4e4f6834889851cd6634ab0e9bd58b3abfc93e86d97819419679cc3100"
          ],
          "init": [
            "init",
            "a8a6710d851628e1003c6ee41090058caae867fbde1836ae051a0086c33f3bab"
          ],
          "homeContent": [
            "homeContent",
            "72269a40be8b26e17e1d1dd2ed65b04ffcdc36907dc581d6171116fc064de5c9"
          ],
          "categoryContent": [
            "categoryContent",
            "b0f517240daee63d2b0a22a3a856f76a946652ffaefb2c07ac3990cec0b5685c"
          ],
          "detailContent": [
            "detailContent",
            "024bbee492035d18bc53ab3325f50364af669da8f22daed1a8903006240d24be"
          ],
          "playerContent": [
            "playerContent",
            "a30b6af0c9afd5a99f7b6ff3abd549034f58d06e3ccebf82331656636c63283e"
          ],
          "searchContent": [
            "searchContent",
            "122934e7cc89838f2ece35237094f338c20fb87ccf2be7dd0c39af5854deb1f6"
          ]
        },
        "shortArray": [
          "cea67e4ed148bcdcb7603e5d9ab7bda1a6aba041bd7d0e7411bb2206e678db81",
          "short",
          10,
          539
        ],
        "triples": {
          "defaultHost": [
            0,
            23,
            2257
          ],
          "aesKey": [
            168,
            16,
            2630
          ],
          "aesIv": [
            184,
            16,
            2526
          ],
          "sportsPath": [
            200,
            29,
            1357
          ],
          "detailPath": [
            366,
            29,
            2074
          ],
          "userAgent": [
            239,
            13,
            2668
          ],
          "clientVersion": [
            266,
            7,
            2797
          ]
        }
      },
      "alllive-v1": {
        "cls": "Lcom/github/catvod/spider/Alllive;",
        "methods": {
          "<init>": [
            "<init>",
            "fb622db12d8448755e959f12e1d358979254fedab1059038bbd3cea26e89073f"
          ],
          "init": [
            "init",
            "db6512d6443f785d531100a87e92b7b280515b82a4bdaeba601125677d1a342d"
          ],
          "homeContent": [
            "homeContent",
            "0d5b9902224362774aba7b4aebb4049a7a030e518920ed66585dac1c36b1fcaa"
          ],
          "categoryContent": [
            "categoryContent",
            "0297641313720170e98573fb361afe5bdfdc93f881ae438c2f7f4032aaedd885"
          ],
          "detailContent": [
            "detailContent",
            "786b774e719a27f5d6f790664cae19c095db83638e611f4ca94486ca33a9fa1e"
          ],
          "playerContent": [
            "playerContent",
            "41ac8db23ab0c6517b6219f704715c3fb855f0379a78c80984bb0f102f9196f7"
          ]
        },
        "shortArray": [
          "39641da53471294aec1d9b43e0ec070140594ea50019d3787f8d7f8090190d77",
          "short",
          10,
          1672
        ],
        "triples": {
          "huyaLoginUrl": [
            1486,
            42,
            393
          ],
          "huyaLoginBody": [
            1528,
            64,
            2109
          ],
          "huyaBase": [
            1271,
            21,
            1229
          ]
        }
      },
      "tingshu275-v1": {
        "cls": "Lcom/github/catvod/spider/Tingshu275;",
        "methods": {
          "<init>": [
            "<init>",
            "57439bd7f593875b3964b7473f27895159428faaca24877865b5c486e378712e"
          ],
          "init": [
            "init",
            "e0faa95a11d73f16fb1d4d7f63fcad8cfdf7608ca797ca6e98320d2c7586b985"
          ],
          "homeContent": [
            "homeContent",
            "7756ef16fba1a88c98d21963c561ce05fad5a01dbaa3a07da80f0e9bb2ed26a0"
          ],
          "categoryContent": [
            "categoryContent",
            "bca3ecdcc9d9517e596598a8e4164e138b13562b51287f83684299dcd005da2c"
          ],
          "detailContent": [
            "detailContent",
            "4467bc37fcd240f768bf20a744009353f4c017d9539c32a752ce1804f58e7886"
          ],
          "playerContent": [
            "playerContent",
            "173de94fd23e7a5726fcb89b4a2eb00cebd065620976a0db74bf54922fbcaa7c"
          ],
          "searchContent": [
            "searchContent",
            "cec347e28d2cb8130c1b041b0e745c90920daa9ba5c1e4b29f28d5a4bb788170"
          ]
        },
        "shortArray": [
          "72352e70cb4d03845f2e8818555f228253135fef249a9039a18bf39b380ca8a9",
          "short",
          10,
          620
        ],
        "triples": {
          "defaultHost": [
            0,
            23,
            3245
          ],
          "configUrl": [
            353,
            51,
            328
          ],
          "apiUa": [
            33,
            29,
            2025
          ],
          "playUa": [
            492,
            50,
            383
          ]
        }
      },
      "seedhub-v1": {
        "cls": "Lcom/github/catvod/spider/Seedhub;",
        "methods": {
          "<init>": [
            "<init>",
            "a7f2139e8b13fa669b270f92bc9ed504383d663fbb42f49f85188d0dd8464d02"
          ],
          "init": [
            "init",
            "b8d3c392350154a5c37a27e921d6754b7f9a6e4438ee24aa34c530e34678da5c"
          ],
          "homeContent": [
            "homeContent",
            "05028cfca254b87bf4dbfbe6c03ffbb18c50c76834844ef090d760eeb0653786"
          ],
          "categoryContent": [
            "categoryContent",
            "cda3cc3ce4720ee18dfa11ba018a5ed8c08acdce63c57680cfa4cd2133091573"
          ],
          "detailContent": [
            "detailContent",
            "a00903c7a66ed492c5d29fb612cf42778a9fe1cd8667d5cbfaea68e813332399"
          ],
          "searchContent": [
            "searchContent",
            "e2b7da6f1aba5a0ff9b3fd3e19aa5e81b0fbc85dcd79b08e682c4d1382b5a6e5"
          ]
        },
        "shortArray": [
          "0c7433162f598594152c88a51b3dbe3a4f321fe2daedbed0c4e401e8745a411e",
          "short",
          10,
          1697
        ],
        "triples": {
          "defaultHost": [
            0,
            20,
            2969
          ]
        }
      },
      "szps-v1": {
        "cls": "Lcom/github/catvod/spider/S_zps;",
        "methods": {
          "<init>": [
            "<init>",
            "4aab3563847839cc229d95dc0587232fd37c83e6b62c42915137fa8cb413ab81"
          ],
          "init": [
            "init",
            "05a339fc288f53ba8e40232aabf7b842c7a97e1d8324347644434b8f147e1838"
          ],
          "homeContent": [
            "homeContent",
            "f0e55d27a38fc2501bd0b8549d0432c990f4bb7d86d08edebb4aa08e03784766"
          ],
          "categoryContent": [
            "categoryContent",
            "50d287b6eec94511de68039925de99df2027612bf81b6fca8483727a01bc362f"
          ],
          "searchContent": [
            "searchContent",
            "73029ea15e796b7d4d230501f4ecaeeb0f5236e173cb7ac6d647ed949c1b4099"
          ]
        },
        "shortArray": [
          "b31fee2d1d57491df11f710842d0d0f41bd27af26e7a6dcd9127977a446d692a",
          "short",
          10,
          1107
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            1986
          ],
          "searchApiPath": [
            22,
            15,
            2296
          ],
          "loginPath": [
            70,
            14,
            1708
          ]
        }
      },
      "ypanso-v1": {
        "cls": "Lcom/github/catvod/spider/YpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "1086d7cdecf02c1a725fa5dc2c947bb26d0141ae83203458f33a4aa025342f2a"
          ],
          "homeContent": [
            "homeContent",
            "59ff768f03e8fd42e8a2baa8323957782bbcf185d5c151cc8ab1e9d2660a05e7"
          ],
          "detailContent": [
            "detailContent",
            "7e4d1381da9afc85d49b714d6c04ac636f5c3f06e0a9012a1db696a9b6b40ef8"
          ],
          "searchContent": [
            "searchContent",
            "f3c554a205a757a6cd1fb87916395ecd37a6193ff47b82805694c686665c459f"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "69a393a4e58436b3652aae7860121374ff018b25ecc761a3ea9b0a21569af712",
            21
          ],
          "origin": [
            "searchContent",
            "69a393a4e58436b3652aae7860121374ff018b25ecc761a3ea9b0a21569af712",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "69a393a4e58436b3652aae7860121374ff018b25ecc761a3ea9b0a21569af712",
            75
          ],
          "searchUrl": [
            "searchContent",
            "69a393a4e58436b3652aae7860121374ff018b25ecc761a3ea9b0a21569af712",
            84
          ]
        }
      },
      "bpanso-v1": {
        "cls": "Lcom/github/catvod/spider/BpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "1086d7cdecf02c1a725fa5dc2c947bb26d0141ae83203458f33a4aa025342f2a"
          ],
          "homeContent": [
            "homeContent",
            "59ff768f03e8fd42e8a2baa8323957782bbcf185d5c151cc8ab1e9d2660a05e7"
          ],
          "detailContent": [
            "detailContent",
            "7e4d1381da9afc85d49b714d6c04ac636f5c3f06e0a9012a1db696a9b6b40ef8"
          ],
          "searchContent": [
            "searchContent",
            "3a3ec11e580d7e12584463750f2e71b2fb30e8912c435f33619855b547572b84"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "4dfaf0aa86baad77ce92383928006c8384b8774642d531025c96d1c7e9959e15",
            21
          ],
          "origin": [
            "searchContent",
            "4dfaf0aa86baad77ce92383928006c8384b8774642d531025c96d1c7e9959e15",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "4dfaf0aa86baad77ce92383928006c8384b8774642d531025c96d1c7e9959e15",
            75
          ],
          "searchUrl": [
            "searchContent",
            "4dfaf0aa86baad77ce92383928006c8384b8774642d531025c96d1c7e9959e15",
            84
          ]
        }
      },
      "kkss-v1": {
        "cls": "Lcom/github/catvod/spider/KkSs;",
        "methods": {
          "<init>": [
            "<init>",
            "f74c62ef8a4028cbfda08333a41a0fd5f929009e4f9a13cf1acde724c5733eee"
          ],
          "init": [
            "init",
            "e6c4285443b53abddd70329fb980222dc5655c4f689327777e477384b66fc80b"
          ],
          "homeContent": [
            "homeContent",
            "e8c622fe85d00b36787d74ca372c1c7d32349508561a2d240f0cc228dad7c205"
          ],
          "detailContent": [
            "detailContent",
            "5d715d2991e55b68928c564fbecadc1e3715df1afce1cc1f1f3a00f45b33e872"
          ],
          "searchContent": [
            "searchContent",
            "a42380250cd93a3bf796cb88caa7eebbdb5cc3651b8bddd9b2738d2fbf83c1c2"
          ]
        },
        "shortArray": [
          "8e6d503e363f73c542978030bed2179c345c89ccac16e56e00209e42058078fe",
          "short",
          10,
          609
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              19,
              1766
            ],
            [
              19,
              20,
              3071
            ],
            [
              39,
              22,
              3233
            ],
            [
              61,
              22,
              495
            ],
            [
              83,
              19,
              2508
            ],
            [
              102,
              18,
              3198
            ],
            [
              120,
              22,
              949
            ],
            [
              142,
              21,
              1643
            ]
          ]
        },
        "triples": {
          "detailPath": [
            167,
            24,
            476
          ]
        }
      },
      "uuss-v1": {
        "cls": "Lcom/github/catvod/spider/UuSs;",
        "methods": {
          "<init>": [
            "<init>",
            "248885bc48685d075b19f8b57bf2efec04b367adde7c2f28821c4707c215e3e2"
          ],
          "init": [
            "init",
            "ba2b0a2a95001d8f46080ee5df0cf52a3d517f9433c14af4c1f91a143593dbd5"
          ],
          "homeContent": [
            "homeContent",
            "b65991931058108cb7feb170430767cedf4afd2568efcfabe1345b4fa185be00"
          ],
          "detailContent": [
            "detailContent",
            "8d0d5dee42bf5d09e46493329ee75ae7ca8c0ee5edf54ed14e573a087f1bf17d"
          ],
          "searchContent": [
            "searchContent",
            "02b4668f81e6c790de2250471e04fc73dcb9bc1c81423ac7126aafaec8843e18"
          ]
        },
        "shortArray": [
          "81ec1316064e851925954bfd690cb44422a6b34dad8d157b697a4f69772ca504",
          "short",
          10,
          616
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              22,
              3240
            ],
            [
              22,
              22,
              2890
            ],
            [
              44,
              28,
              2256
            ],
            [
              72,
              22,
              2308
            ],
            [
              94,
              19,
              3134
            ],
            [
              113,
              21,
              1607
            ],
            [
              134,
              25,
              2685
            ]
          ]
        },
        "triples": {
          "detailPath": [
            163,
            24,
            742
          ]
        }
      }
    }
  },
  "e7375830bcd065b264239e1f0e7da4c99d75abf71e1b6edf50e225ae8b0f4b7e": {
    "nativeSha": "fac9e3937d9928e437ebff79bc5164df418a6adb212494ef21c273579b045dcb",
    "mask": 183,
    "spiders": {
      "jpys-v1": {
        "cls": "Lcom/github/catvod/spider/Jpys;",
        "methods": {
          "<init>": [
            "<init>",
            "5fe6c5169cb031d257085af46a961ff2183fcb8350a4e8f355f29b580b5abcf5"
          ],
          "init": [
            "init",
            "5954acc1e2c7a8c456bfbfec5fd30947b320ca184048d8350b05e89b4e7f01ee"
          ],
          "homeContent": [
            "homeContent",
            "550a5176799ccb83e18a6f4ce709893b277ea64b1686dae2e859e66eddb8acd3"
          ],
          "categoryContent": [
            "categoryContent",
            "badb3ad582c183c949bb360dc50fa9ebfb867ec50589c33294a16c5566f262ba"
          ],
          "detailContent": [
            "detailContent",
            "6a26efaa805b25d66ca8b82aab0bec29a17a24086c2a21c649c8fe1930648b5f"
          ],
          "playerContent": [
            "playerContent",
            "9f9efec1956a3b26f4dd91747d74f740783db65c2813d22fc8dfd2553d84603f"
          ],
          "searchContent": [
            "searchContent",
            "94d6d7e10701f96ceb7e3574ea731e3329f26cacc885d7451319f8cbb1a82f82"
          ]
        },
        "shortArray": [
          "e24b00c7fe78b64101349abaa58c365db75381d0cffe628c20120d7ef27e39d6",
          "short",
          10,
          1191
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            2539
          ],
          "signSuffix": [
            68,
            40,
            1677
          ],
          "userAgent": [
            670,
            102,
            1420
          ]
        }
      },
      "jpj-v1": {
        "cls": "Lcom/github/catvod/spider/JPJ;",
        "methods": {
          "<init>": [
            "<init>",
            "3473371add15e01bf10967cc5181daa31536913e249818b6be188ee991d72ab5"
          ],
          "init": [
            "init",
            "d1003d65f826acfdb805f31203dcae1d82ea13890facfb7fb408f1700f977f14"
          ],
          "homeContent": [
            "homeContent",
            "9666be309a7689a59aa2ebefee9a5f7b1bde505c483935ea619cbbea3fabdee1"
          ],
          "categoryContent": [
            "categoryContent",
            "34a6192f3282c38f06d90d64ee30fba9e2ade0f92d18bf0cca65f1ee33589888"
          ],
          "detailContent": [
            "detailContent",
            "33cccd14da646a7a0ce0be9135539c5c03169be007123e828c6e1cea48a92257"
          ],
          "playerContent": [
            "playerContent",
            "ecf90da70d8cf5ad8837c94878f2658bcf6b3693f898c8ff86cd2c1ed4ad421f"
          ],
          "searchContent": [
            "searchContent",
            "878f0dee83340769af6b0002b759a3bb9d397801114a47042eb74ea5cbadc146"
          ]
        },
        "shortArray": [
          "2cfdd7cca216e8c7b75430a6032b340c6965416a30fbe86c66ae1edf27d226b6",
          "short",
          10,
          727
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            2741
          ],
          "alidnsUrl": [
            517,
            63,
            1803
          ],
          "fanPrefix": [
            593,
            15,
            1968
          ],
          "domainConfigPath": [
            608,
            37,
            2358
          ],
          "userAgent": [
            34,
            247,
            535
          ]
        }
      },
      "nmyswv-v1": {
        "cls": "Lcom/github/catvod/spider/Nmyswv;",
        "methods": {
          "<init>": [
            "<init>",
            "7fc18f84aa4beea40324298046f8cac204503f9b4899ff11197d9a19b146f8b3"
          ],
          "init": [
            "init",
            "7ef149265945a651b2d7a846f9d15e177367909602d5321935147fb4541cf336"
          ],
          "homeContent": [
            "homeContent",
            "2dd501b7390431fd5fdef5a6c425370c385e601366ac7853ad8e0e26b91e0854"
          ],
          "categoryContent": [
            "categoryContent",
            "a94826f218fb6d66b3927b2ab51ab004336fe442af45509cc76004475e5424ec"
          ],
          "detailContent": [
            "detailContent",
            "0223ff7113df878838da4847489ccd9cc55b3977268184a7cbb416147032ed65"
          ],
          "playerContent": [
            "playerContent",
            "4adaa67f3d785bb9505d96827c7d849f643d92f40a029e5129ee17956f98ad13"
          ],
          "searchContent": [
            "searchContent",
            "ede6e8b158aa5f62d8bc8e707849d0bbb1e9d52013fb439a1526367e6cc4c62f"
          ]
        },
        "shortArray": [
          "74fae4639fb3d8b56b1d105bfab677c4a1d68c80a062e58336c1a8a85a615f42",
          "short",
          26,
          893
        ],
        "triples": {
          "defaultHost": [
            0,
            25,
            2884
          ]
        }
      },
      "hmys-v1": {
        "cls": "Lcom/github/catvod/spider/Hmys;",
        "methods": {
          "<init>": [
            "<init>",
            "57386c0f46616c335476bc3b836e5e07b7d6ed62c35b6dde597599decae4b838"
          ],
          "init": [
            "init",
            "e547ad971cfddb9aa8d3b96ab8e36b479fe6b1aa5a447491adc7dfc27019a627"
          ],
          "homeContent": [
            "homeContent",
            "c60a99b710038ffb63d54273af3c81b19f2bb7b7796de44eae54dbe7a9797749"
          ],
          "categoryContent": [
            "categoryContent",
            "749e0f96400aa65eb01dc1636479d63d96c8bfd83bba9f930132f2ae14cb5e00"
          ],
          "detailContent": [
            "detailContent",
            "77c1b6b35201098d03975bd49d26a993f8970d4d607fa1a723fca4c73d1a72f9"
          ],
          "playerContent": [
            "playerContent",
            "2890d92e339b7c0b263996ebeda11327de94a2136e2e99efb19cf881b6f058e3"
          ],
          "searchContent": [
            "searchContent",
            "86a468200b0912b1dd4604400b13408c0d352f5e63f5e00083cdfa86cc86a369"
          ]
        },
        "shortArray": [
          "91fc6c89373080443a1f89786d86ccafd4711c94390f6354b87fc3deda3436d3",
          "short",
          10,
          2758
        ],
        "triples": {
          "aesKey": [
            0,
            32,
            3272
          ],
          "aesIv1": [
            32,
            16,
            1938
          ],
          "aesIv2": [
            48,
            16,
            2628
          ],
          "defaultInitUrl": [
            64,
            43,
            1124
          ],
          "appName": [
            107,
            14,
            2382
          ],
          "channelCode": [
            121,
            7,
            762
          ],
          "packageName": [
            128,
            5,
            382
          ],
          "signKey": [
            133,
            21,
            1052
          ],
          "v2InitUrl": [
            64,
            43,
            1124
          ],
          "v2Channel": [
            121,
            7,
            762
          ],
          "v2Pkg": [
            133,
            21,
            1052
          ],
          "v2SignKey": [
            154,
            32,
            2357
          ],
          "uaOk412": [
            192,
            13,
            3042
          ],
          "uaOk49": [
            205,
            12,
            2773
          ]
        }
      },
      "app99-v1": {
        "cls": "Lcom/github/catvod/spider/App99;",
        "methods": {
          "<init>": [
            "<init>",
            "321ccfbc929b4564606690c51d6cc7ebf6564ec6be5dc26526f5c6ca2086cb82"
          ],
          "init": [
            "init",
            "3bd18c864d9b6a242d1cee728f67b50adb61403d8060392db6ea6ff0909adbf7"
          ],
          "homeContent": [
            "homeContent",
            "f46d1abfa72f570d4fe3f93c27069ee19d86ba6f131364f62004106e31a7e26a"
          ],
          "categoryContent": [
            "categoryContent",
            "6c79047d965808d193a513e1509acbbc3cfbe4f9c406e81458a7c1c8aa10abe6"
          ],
          "detailContent": [
            "detailContent",
            "f60cb29f9f6894184fa1d89319082af8e193583d843dac5d890ac49e706157ba"
          ],
          "playerContent": [
            "playerContent",
            "44e7f4d820f434180e5368d0d79c6aa4cae53a01f6baae77c6e8df6f9b9d89bc"
          ],
          "searchContent": [
            "searchContent",
            "a732d2cbf733302cc141936c54aec027d0ac78ecacffdda5c14000cb27728568"
          ]
        },
        "shortArray": [
          "13a65dada1e7e2cf4dcfc0782bb268c29f2f043b8a072af1bdb556e700e6a959",
          "short",
          10,
          1665
        ],
        "triples": {
          "defaultIv": [
            1227,
            16,
            1773
          ],
          "userAgent": [
            1290,
            115,
            1717
          ]
        }
      },
      "appsx-v1": {
        "cls": "Lcom/github/catvod/spider/AppSx;",
        "methods": {
          "<init>": [
            "<init>",
            "f3dc1fed1246d1d7259e0cd23f16e54785b2b11e925256791729f6cef21b5f03"
          ],
          "init": [
            "init",
            "29246cd9b77903d60143526595434ea5aabf1170307c25f9ebc045a4faadfa35"
          ],
          "homeContent": [
            "homeContent",
            "f027b92b728dd66c0115cf19b470188d3e783a504c7b3d95d138132789538619"
          ],
          "categoryContent": [
            "categoryContent",
            "7ee53cacb969d86e4fd81a49e12e3274d191a0dc567346b72e111169767227dc"
          ],
          "detailContent": [
            "detailContent",
            "f878a027779188de877bdd59d09bff7e7e48e12798c838d797e27da21aa3b028"
          ],
          "playerContent": [
            "playerContent",
            "cc0a776742d68bb276eda90171f26baa727f60f759b49a7b7dd1803b9d558401"
          ],
          "searchContent": [
            "searchContent",
            "c9f8de28f4bfeab3539f1ad591bc63df7bfd81fc7a37333a49f5ce83d5d998e8"
          ]
        },
        "shortArray": [
          "3ef0a4c4e464c54fa3f967eff05bac6056cd182604e5e40193a06131b65a2405",
          "short",
          10,
          2283
        ],
        "triples": {
          "defaultVerStr": [
            0,
            3,
            1446
          ],
          "defaultPath": [
            3,
            19,
            3120
          ],
          "qijiPath": [
            1795,
            20,
            1908
          ],
          "vodPath": [
            1815,
            9,
            2743
          ],
          "uaOk310": [
            299,
            13,
            1296
          ],
          "uaOk314": [
            312,
            13,
            2098
          ]
        }
      },
      "newcz-v1": {
        "cls": "Lcom/github/catvod/spider/NewCz;",
        "methods": {
          "<init>": [
            "<init>",
            "59bb940b6b9f4ebde6b308014a6fc838d935e6698a7b28a8df06fdda56109410"
          ],
          "init": [
            "init",
            "4a6c3198f8d0578f2d10204a97693daaa7c32f8f814a58aca8c635c15c64bbdc"
          ],
          "homeContent": [
            "homeContent",
            "6c5e5ffaf8faff96035696c0f0d0c96497442c674fd76b1b44e6980b00b97004"
          ],
          "categoryContent": [
            "categoryContent",
            "8c9c94ce35f6d68134e5de9cec8fbb8af047355c3b2b3615675b2e99b7bc9772"
          ],
          "detailContent": [
            "detailContent",
            "3326898f9b5ddb5cab12baca50d5434f865f660ef5afedd17d9e203585e613ed"
          ],
          "playerContent": [
            "playerContent",
            "5cab34e20ddb66b4795553fab0186734f38f9a234a214a1bdc247b3e6908ee6d"
          ],
          "searchContent": [
            "searchContent",
            "df939507a031b18224ee6034456fab025472f28e4a5987481989588f1bc1fb5f"
          ]
        },
        "shortArray": [
          "89224269c4242613e7df06b59c9e16385cf6744a933731941718e365a83e784f",
          "short",
          10,
          3150
        ],
        "triples": {
          "defaultHost": [
            0,
            21,
            2949
          ],
          "altHost": [
            21,
            20,
            1949
          ],
          "searchApi": [
            2528,
            46,
            1288
          ],
          "userAgent": [
            2647,
            116,
            573
          ],
          "playUa": [
            2023,
            117,
            3063
          ],
          "czFunHost": [
            2242,
            25,
            1774
          ],
          "czFunKey": [
            2267,
            16,
            2370
          ],
          "nowwonHost": [
            2191,
            24,
            1460
          ],
          "pyHost": [
            2467,
            28,
            1358
          ]
        }
      },
      "libvio-v1": {
        "cls": "Lcom/github/catvod/spider/Libvio;",
        "methods": {
          "<init>": [
            "<init>",
            "a987ce5a4dd41c71e08fc5a275c13295763ce82d5a589d6f85f1846e24599f75"
          ],
          "init": [
            "init",
            "ffaa4750b8e8fe5bb2f451d3b6ec89a6bf928013f8ad251c68c2ffce05e1c52c"
          ],
          "homeContent": [
            "homeContent",
            "4d22bdd49a0f424370092c034cf8ae1a3a1474d9e550b17bea35e25682066ece"
          ],
          "categoryContent": [
            "categoryContent",
            "ee879325aedb2ad803965c921caf6578a628c867427fbd430e29cbedcd40850a"
          ],
          "detailContent": [
            "detailContent",
            "7fc4ac88bdfba4b0b954d1b9649552149c12337c5aa0bd5032dbf54f8c5e6cf1"
          ],
          "playerContent": [
            "playerContent",
            "f3cc96fce1a902a762835ec6f4afc2a07dc0776d43b3c9d9811dcd4d6e655591"
          ],
          "searchContent": [
            "searchContent",
            "235b528a09cdd733a76853bd19dd678f3cdb8d4562d8e2c9facea2ed2292be8d"
          ]
        },
        "shortArray": [
          "b092c1402e14bf634f3d8893429d5cfdd2c64dc3a1fe6488fe6181e9a0daa0f1",
          "short",
          10,
          2012
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            3011
          ],
          "headersBlock": [
            210,
            560,
            839
          ],
          "playUa": [
            1606,
            102,
            861
          ]
        }
      },
      "ygp-v1": {
        "cls": "Lcom/github/catvod/spider/YGP;",
        "methods": {
          "<init>": [
            "<init>",
            "10670bd041a69c8e509a6857b09be2798681e20431b625d63925e463f04b530d"
          ],
          "init": [
            "init",
            "4007b7e6fd74198f416a78a1617248796a7c768f089a1e60347317e613ea898a"
          ],
          "homeContent": [
            "homeContent",
            "dd8f09e1c9903c8fc1ad8e1d8ebb2ae8b81fef28cf79bad9ee966e8cb530fd00"
          ],
          "categoryContent": [
            "categoryContent",
            "b9afe9e2a8c1a77c322cced999bf0e10953eede1cdc7c6383c17780a7660ad9f"
          ],
          "detailContent": [
            "detailContent",
            "1ed7f90a55cb75d2c7808419ff90e20c679b8d421a0ee42191437f736a96f882"
          ],
          "playerContent": [
            "playerContent",
            "a28e5e388a0d2dbf0cc19ccbdff84b7786cca47a0c2892be8796e49fc33bdc46"
          ],
          "searchContent": [
            "searchContent",
            "ec4d55452656b2ffd5d024da6d661a2978b9dc8d3a6060f7ff702721864d693f"
          ]
        },
        "shortArray": [
          "029f8918accb607424c8e68f726bee87b0c52b2b244e12f89d7bebbb3665f928",
          "short",
          10,
          1268
        ],
        "triples": {
          "defaultHost": [
            4,
            21,
            3178
          ],
          "userAgent": [
            988,
            110,
            2093
          ]
        },
        "literals": {
          "filtersJson": [
            "init",
            "4007b7e6fd74198f416a78a1617248796a7c768f089a1e60347317e613ea898a",
            5
          ]
        }
      },
      "kanqiu-v1": {
        "cls": "Lcom/github/catvod/spider/Kanqiu;",
        "methods": {
          "<init>": [
            "<init>",
            "891685ecb4854f118fb0ce1353cef6c2597a0bd8f8ef352ba3d5cfb5716cf67f"
          ],
          "init": [
            "init",
            "550753d764e7326c8cd3e0b50b289e7ffb1304b7a73e075426fc82fe6f72cef3"
          ],
          "homeContent": [
            "homeContent",
            "92be5dcf2536a697e526a02894176df534c999ea141eefea634206031a274dde"
          ],
          "categoryContent": [
            "categoryContent",
            "071a842c1bd7bda327af2ef828b3f4b5c27eb119b54cfb71dde20e7dd26d33c0"
          ],
          "detailContent": [
            "detailContent",
            "8a91ad820cdb98bcc69b15f2e3ce72e95315f3714e6eff35641cfc5436416cac"
          ],
          "playerContent": [
            "playerContent",
            "0cf3209d865c483569627c4d0d83565a8461999af3e8a20d999a6147a5e157cf"
          ]
        },
        "shortArray": [
          "8137450bc5a3de809a40aec17c6b1b8d50255ed4cce52fd7db214e70bc15b695",
          "short",
          26,
          1224
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            848
          ],
          "userAgent": [
            32,
            111,
            2164
          ],
          "filtersJson": [
            373,
            767,
            532
          ],
          "xxteaKey": [
            1197,
            24,
            2022
          ]
        }
      },
      "doubao-v1": {
        "cls": "Lcom/github/catvod/spider/Doubao;",
        "methods": {
          "<init>": [
            "<init>",
            "4dc6c0d64c4ac3e2aac606ce587274491cfc4aa3fe5dcafc859d511f87f33613"
          ],
          "homeContent": [
            "homeContent",
            "4e2ab586d507b4065cc9eb80ed246ece4406f0f48c4a7892ea2d394af69375e7"
          ],
          "categoryContent": [
            "categoryContent",
            "b6f0f9e9a4275f53674a7ce42b327e9bfed64558c3bba85ed385f2ce7b94745c"
          ],
          "detailContent": [
            "detailContent",
            "71bc323a8dca4dfeae16fbb8539416cc9e4d9069d2b671545810d7af1cf8997c"
          ],
          "playerContent": [
            "playerContent",
            "b8056e086f7432145f0301ce0d6ff5a63993386de1fb22beb430856b35aef2de"
          ]
        },
        "shortArray": [
          "a28873cbf85dc90f2fdf8705edcd6a2bec51cd883832c706f4254e8604f0f31d",
          "short",
          10,
          1411
        ],
        "triples": {
          "defaultHost": [
            0,
            27,
            2429
          ],
          "scheduleUrl": [
            27,
            49,
            1770
          ],
          "playbackUrl": [
            76,
            44,
            1446
          ],
          "userAgent": [
            120,
            111,
            767
          ]
        }
      },
      "livegz-v1": {
        "cls": "Lcom/github/catvod/spider/LiveGz;",
        "methods": {
          "<init>": [
            "<init>",
            "afce0f655506badebbe6e28e89cf74a38752b8603b6159fbdc0b594bc3e18982"
          ],
          "init": [
            "init",
            "f3a18721dc860fd035eaeb8990823279025de8a6fa60578a20091a19728f9429"
          ],
          "homeContent": [
            "homeContent",
            "74f06e38a48147aa3d7333d17ca10f5d5198040581369bbfc6228eb1ea2db955"
          ],
          "categoryContent": [
            "categoryContent",
            "a575209716cc1f9e5dce46a28094168f7d5f2c4721e20766c2e9f62d3b58af36"
          ],
          "detailContent": [
            "detailContent",
            "18dfb0abf40b669a0d2800b519b774c9212968b416a98ccfd4bd901a27c83511"
          ],
          "playerContent": [
            "playerContent",
            "1f65cd5caef40689da39677a50aeeb3b79ce4a8f887045354cb8f91338c55e98"
          ],
          "searchContent": [
            "searchContent",
            "fa935dd2ba187d5fda17a52b51afd3b5058d9246857d4466bde8bc0597c15fc3"
          ]
        },
        "shortArray": [
          "1258d3b72a5b66b89c44c5c07d66ee601daaeecd9b37f809c35f1f2c27c0f571",
          "short",
          10,
          539
        ],
        "triples": {
          "defaultHost": [
            0,
            23,
            2526
          ],
          "aesKey": [
            168,
            16,
            2626
          ],
          "aesIv": [
            184,
            16,
            1295
          ],
          "sportsPath": [
            200,
            29,
            3044
          ],
          "detailPath": [
            366,
            29,
            3076
          ],
          "userAgent": [
            239,
            13,
            477
          ],
          "clientVersion": [
            266,
            7,
            2608
          ]
        }
      },
      "alllive-v1": {
        "cls": "Lcom/github/catvod/spider/Alllive;",
        "methods": {
          "<init>": [
            "<init>",
            "f340e85b7d1831180b1b72a42be2a11233d2be096db8685543d0c79f081407d9"
          ],
          "init": [
            "init",
            "7e3a02e6cc1883007cf86f3e4f6c7999f2f7c64ce51d5114e71ec5bee76cef4b"
          ],
          "homeContent": [
            "homeContent",
            "00c6b0b9a698b8377365736ce6ab47bfe45cd7b1e97ac65ea0f52446412d5e30"
          ],
          "categoryContent": [
            "categoryContent",
            "cd4adb0a09b52547e7f27753c7fa7750c0f201750301cfcde3d8c847f524b475"
          ],
          "detailContent": [
            "detailContent",
            "323b27e57fb27354f5cf4b27f0157c47011819278dde7b6ced4b6477b5569b49"
          ],
          "playerContent": [
            "playerContent",
            "b0eaac4cff402b0486f28c4321dddd279da73c7dfd891fd1ce98ff7bd5332a80"
          ]
        },
        "shortArray": [
          "69e0674b16d7bf765b5d9cfc201105ce8849c93424ad65320456def690bbb503",
          "short",
          10,
          1672
        ],
        "triples": {
          "huyaLoginUrl": [
            1486,
            42,
            3147
          ],
          "huyaLoginBody": [
            1528,
            64,
            2505
          ],
          "huyaBase": [
            1271,
            21,
            493
          ]
        }
      },
      "yueting-v1": {
        "cls": "Lcom/github/catvod/spider/YueTing;",
        "methods": {
          "<init>": [
            "<init>",
            "97c9a2d13edbe8a63d1f30cce647cc80eae1f71aa613d31b90fe638fb320f5f0"
          ],
          "init": [
            "init",
            "65e77ca12de1b158f93f9bfb14d590759e49b3c0fa9956850a8af3f1f9e59a02"
          ],
          "homeContent": [
            "homeContent",
            "a91e6942485bd3a9f704d471d8c6e5b8a2bb5cb90aef00f32b97bda7d50152fe"
          ],
          "categoryContent": [
            "categoryContent",
            "9ac9fc45dd1afec9dafded75593e5a83ff3e7b2f303c0190f2f35b134cbdeeca"
          ],
          "detailContent": [
            "detailContent",
            "c5fefa07ec7fcadd207eed20dbce9c669215ead2862688764666832761612759"
          ],
          "playerContent": [
            "playerContent",
            "347a776f5f6fbe5572fdf19f1482d3d81f7a1409336c1e85c2665502284b45b2"
          ],
          "searchContent": [
            "searchContent",
            "0a732f47e2fad6d21674d7b3836c52d6d193f2387eb3f953e5901db6fb1846cb"
          ]
        },
        "literals": {
          "headUrl1": [
            "<clinit>",
            "df8a53f2b56547e3fc22b6ebc9a3ed31c107c58b1fec37c707b192702b8d2354",
            0
          ],
          "headUrl2": [
            "<clinit>",
            "df8a53f2b56547e3fc22b6ebc9a3ed31c107c58b1fec37c707b192702b8d2354",
            2
          ],
          "fallbackApi1": [
            "<clinit>",
            "df8a53f2b56547e3fc22b6ebc9a3ed31c107c58b1fec37c707b192702b8d2354",
            10
          ],
          "fallbackApi2": [
            "<clinit>",
            "df8a53f2b56547e3fc22b6ebc9a3ed31c107c58b1fec37c707b192702b8d2354",
            12
          ],
          "browserUa": [
            "<init>",
            "97c9a2d13edbe8a63d1f30cce647cc80eae1f71aa613d31b90fe638fb320f5f0",
            3
          ],
          "apiUa": [
            "yq",
            "e5fb564d9f86be016043455ee28784161be921038c05319140614f337524c0cb",
            7
          ],
          "jsonBase": [
            "categoryContent",
            "9ac9fc45dd1afec9dafded75593e5a83ff3e7b2f303c0190f2f35b134cbdeeca",
            41
          ],
          "albumInfoUrl": [
            "detailContent",
            "c5fefa07ec7fcadd207eed20dbce9c669215ead2862688764666832761612759",
            17
          ],
          "albumChaptersUrl": [
            "detailContent",
            "c5fefa07ec7fcadd207eed20dbce9c669215ead2862688764666832761612759",
            35
          ],
          "filtersJson": [
            "homeContent",
            "a91e6942485bd3a9f704d471d8c6e5b8a2bb5cb90aef00f32b97bda7d50152fe",
            67
          ],
          "referer": [
            "playerContent",
            "347a776f5f6fbe5572fdf19f1482d3d81f7a1409336c1e85c2665502284b45b2",
            2
          ],
          "origin": [
            "playerContent",
            "347a776f5f6fbe5572fdf19f1482d3d81f7a1409336c1e85c2665502284b45b2",
            287
          ],
          "searchUrl": [
            "searchContent",
            "d4e9e2abe20dc15a8160e1c4743c2abaebcbdd74b325d797bfad52963b1b90a2",
            37
          ]
        },
        "extraLiterals": {
          "keyHex": [
            "Lcom/github/catvod/spider/YueTingCrypto;",
            "<clinit>",
            "378c39535f9b8535f34bf471c9a7e1683502f5e46909ef62893805542e2f73c9",
            0
          ]
        }
      },
      "seedhub-v1": {
        "cls": "Lcom/github/catvod/spider/Seedhub;",
        "methods": {
          "<init>": [
            "<init>",
            "9d0563fd08f2a2e47abf21af1505222ab295ce8ddcdb89103255f68e7e10a845"
          ],
          "init": [
            "init",
            "321abcced431838f2266242b671954e3bb222f9a8d506c6f935939d6b158a49c"
          ],
          "homeContent": [
            "homeContent",
            "38563c7088502e9eb81e8d54495c74520cf580c474d12dde0404b875e72b45ab"
          ],
          "categoryContent": [
            "categoryContent",
            "bf4981d322f548253575dd6f747a24843f197d100542d02e4874ab25df8ea16e"
          ],
          "detailContent": [
            "detailContent",
            "8c7bd9bfb2592216c1818839934e21e8781d1bbeefb735cdae9800fa9ecf121b"
          ],
          "searchContent": [
            "searchContent",
            "a46af27593c985fa5bee5369944c05dcb3939f91f1e2641a3ade570b47f99574"
          ]
        },
        "shortArray": [
          "c5793504301f0a0098927f0b7aa48dbf3b388b77491f85cc31db8f7907f87fe8",
          "short",
          10,
          1697
        ],
        "triples": {
          "defaultHost": [
            0,
            20,
            1969
          ]
        }
      },
      "szps-v1": {
        "cls": "Lcom/github/catvod/spider/S_zps;",
        "methods": {
          "<init>": [
            "<init>",
            "0ee4d2060f04e6447ee2fb19427077d7665b76c58e30514cce7819aa4c649a51"
          ],
          "init": [
            "init",
            "5969e187f0026da716db9ddb8bfbda94fb3e7f579e7aea81d06b1ddb09d3472f"
          ],
          "homeContent": [
            "homeContent",
            "00d9f7a2b3fb00f652812598464f7214dbb99da581dc69aabced4cdbf178460c"
          ],
          "categoryContent": [
            "categoryContent",
            "ccd64feee943abc711a1fdab7c8c7c4d88595249e9adfc9d383675ecb21458f7"
          ],
          "searchContent": [
            "searchContent",
            "35e0091b11d5050c0e4a05c8e321d2853f49345840a47a86fa9d92ea202a02cf"
          ]
        },
        "shortArray": [
          "9877f6cbfec830327f41e2e00bee05de73f0563520faa7a29d67bae4a29e9793",
          "short",
          10,
          1107
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            3092
          ],
          "searchApiPath": [
            22,
            15,
            549
          ],
          "loginPath": [
            70,
            14,
            710
          ]
        }
      },
      "ypanso-v1": {
        "cls": "Lcom/github/catvod/spider/YpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "c007d4a9de607d02afcfd1ab2f1e78be8ba129bd041a345c3e40e12757c2f123"
          ],
          "homeContent": [
            "homeContent",
            "e4f644c67c7f24fb825fa7c7cf266de92cc6db72059e84d0897f5208438f26f4"
          ],
          "detailContent": [
            "detailContent",
            "e3cbdabee3162f11ca926d6ed845a3111d0fc926c3cf5b8f1704b5a539919d28"
          ],
          "searchContent": [
            "searchContent",
            "c62fd51a32b435d28eaa8ee4f544282e163e08c06692a6f5d7da5fb0a98d61ab"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "68c66bc17e28eac1e277390bea88e224bc0b4a6a53083af88b97a3a32713e78d",
            21
          ],
          "origin": [
            "searchContent",
            "68c66bc17e28eac1e277390bea88e224bc0b4a6a53083af88b97a3a32713e78d",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "68c66bc17e28eac1e277390bea88e224bc0b4a6a53083af88b97a3a32713e78d",
            75
          ],
          "searchUrl": [
            "searchContent",
            "68c66bc17e28eac1e277390bea88e224bc0b4a6a53083af88b97a3a32713e78d",
            84
          ]
        }
      },
      "bpanso-v1": {
        "cls": "Lcom/github/catvod/spider/BpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "c007d4a9de607d02afcfd1ab2f1e78be8ba129bd041a345c3e40e12757c2f123"
          ],
          "homeContent": [
            "homeContent",
            "e4f644c67c7f24fb825fa7c7cf266de92cc6db72059e84d0897f5208438f26f4"
          ],
          "detailContent": [
            "detailContent",
            "e3cbdabee3162f11ca926d6ed845a3111d0fc926c3cf5b8f1704b5a539919d28"
          ],
          "searchContent": [
            "searchContent",
            "bf982513da6589420e1e0e69c200f2a8ae929b89b08474c9b6932c13a7650fcb"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "9079aa994742f42464c9ad94c00f366fc81e07c697591738b6066ecd617aab6b",
            21
          ],
          "origin": [
            "searchContent",
            "9079aa994742f42464c9ad94c00f366fc81e07c697591738b6066ecd617aab6b",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "9079aa994742f42464c9ad94c00f366fc81e07c697591738b6066ecd617aab6b",
            75
          ],
          "searchUrl": [
            "searchContent",
            "9079aa994742f42464c9ad94c00f366fc81e07c697591738b6066ecd617aab6b",
            84
          ]
        }
      },
      "kkss-v1": {
        "cls": "Lcom/github/catvod/spider/KkSs;",
        "methods": {
          "<init>": [
            "<init>",
            "ce11e7fb340d078999cbffea0e3bc664d0238c6792ac54b4e19009749e9161ff"
          ],
          "init": [
            "init",
            "c58d7b38cc335a592893c85c0e220e74824167b18d1b0d82b4d7d96f41001a12"
          ],
          "homeContent": [
            "homeContent",
            "23657c84c640d6285ac4454e70102472daf6f24479f7b5d9aac8af36a83e6094"
          ],
          "detailContent": [
            "detailContent",
            "336a62fdd2a64c1b2aa9f7e8022c2fb6a3a42e4a7d8b91b9ae73745bf97c00b1"
          ],
          "searchContent": [
            "searchContent",
            "399b8dacbb7b68989ae67844a66b49460d33cc3f14b8c89be5e465ea4ef2c3b8"
          ]
        },
        "shortArray": [
          "6e2f586af91432f908fc6abfea00dbea4074bb4ac814cf4703ecfd9bdbb9570f",
          "short",
          10,
          609
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              19,
              648
            ],
            [
              19,
              20,
              535
            ],
            [
              39,
              22,
              629
            ],
            [
              61,
              22,
              926
            ],
            [
              83,
              19,
              335
            ],
            [
              102,
              18,
              3120
            ],
            [
              120,
              22,
              413
            ],
            [
              142,
              21,
              504
            ]
          ]
        },
        "triples": {
          "detailPath": [
            167,
            24,
            1805
          ]
        }
      },
      "uuss-v1": {
        "cls": "Lcom/github/catvod/spider/UuSs;",
        "methods": {
          "<init>": [
            "<init>",
            "984e7ade68740ad57df847047da99ba91ae1b9f53f4cfed180330c8835b2b463"
          ],
          "init": [
            "init",
            "398ea9fa7fd7f13e97595eef8e2cce9f216812d4d53bec7bd636c2b230b81949"
          ],
          "homeContent": [
            "homeContent",
            "d011d37a01e52d0ab7db232b0b92bdc57948eb36f411006cc826f3fbadfa0c6f"
          ],
          "detailContent": [
            "detailContent",
            "c231f7806d4c8ea100c734774bb2ac0520d6c9c0badc00a16270edc164e0649a"
          ],
          "searchContent": [
            "searchContent",
            "31bf9934bcf294ebb4d66cad9e0b215e08aa5d5f0a4704145dd48b6c6f1d05f9"
          ]
        },
        "shortArray": [
          "d199aaf627ae31c394c167ae81134cf43e85c8e1a3a6a071c5db8fb732c8f126",
          "short",
          10,
          616
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              22,
              660
            ],
            [
              22,
              22,
              2409
            ],
            [
              44,
              28,
              2684
            ],
            [
              72,
              22,
              1145
            ],
            [
              94,
              19,
              2187
            ],
            [
              113,
              21,
              2892
            ],
            [
              134,
              25,
              2069
            ]
          ]
        },
        "triples": {
          "detailPath": [
            163,
            24,
            2696
          ]
        }
      }
    }
  },
  "da3f3a7afcfcded4d58d9c3a574dfb5cb2ddcc3db4290b7d8b3a7346f9ee8096": {
    "nativeSha": "d5d8adee01e1bdc4c18b445e19ce7c94fb296ca6dce6f18a08786504fc961f01",
    "mask": 21,
    "spiders": {
      "jpys-v1": {
        "cls": "Lcom/github/catvod/spider/Jpys;",
        "methods": {
          "<init>": [
            "<init>",
            "c492483a89fb0015789fcf7a6486f78744bac2e0415945c785ebaca0ca190004"
          ],
          "init": [
            "init",
            "d2d423c6a8e86a720727e390683f31e0015b684fe76cc8201d75cfa2f44b49d9"
          ],
          "homeContent": [
            "homeContent",
            "5c1ea4a92decd4dc1029103682cd14a940121b982c5a380131f9797cfe4d0ce5"
          ],
          "categoryContent": [
            "categoryContent",
            "defc5c0a2ae5c568ee426a553a24285bd28475a6bf3e7cc1ab1bf9f0a1be80c3"
          ],
          "detailContent": [
            "detailContent",
            "35bb5130eba57128e8fd14a7ce16a496065bda9c1ef3da15227c3ebb92da28c6"
          ],
          "playerContent": [
            "playerContent",
            "2dcb232af622947a1de620f10428cf15a27baf577fec3048233fc79bc0b1ddc7"
          ],
          "searchContent": [
            "searchContent",
            "6debe85d98772ac28bdfca698576145e14d80498eed401c64e4654816ca4eb43"
          ]
        },
        "shortArray": [
          "a4ae2f51b23dd7042da0259cad8822af433706be089e33ee8449c78b6aa66159",
          "short",
          10,
          1191
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            1941
          ],
          "signSuffix": [
            68,
            40,
            1647
          ],
          "userAgent": [
            670,
            102,
            789
          ]
        }
      },
      "jpj-v1": {
        "cls": "Lcom/github/catvod/spider/JPJ;",
        "methods": {
          "<init>": [
            "<init>",
            "aa9018ef45da805dbba827827bf20d7ae32b26e5c9f48dd3641bd81e7d978603"
          ],
          "init": [
            "init",
            "206cdd18bb08931f03b39d745550c5d06dfa7b3a19a89030cd9da2cd3fb5df49"
          ],
          "homeContent": [
            "homeContent",
            "ec837d36eb99479250fb60be6658cd549d476bfb289dcf99a523f96395a2af9c"
          ],
          "categoryContent": [
            "categoryContent",
            "d75345b01f31db8a64e47bff8e84e81404406e165d8042b4c7c035baf0b99810"
          ],
          "detailContent": [
            "detailContent",
            "e563c181f4ebd8b5d43756c43c0e32c36b87285bd6627dbb9254a32326777708"
          ],
          "playerContent": [
            "playerContent",
            "7c6db68b7c96af0e98a60619670750db1682ce98e3f0c566d596d041a4415562"
          ],
          "searchContent": [
            "searchContent",
            "e884acfe698ae81029349d09981f58652789ccd0e73b41be51a619f48ee1bb95"
          ]
        },
        "shortArray": [
          "2ee490bebefc9d680dca908a598ab96e58331981f7678c3886c9cb96bc8cafcf",
          "short",
          10,
          725
        ],
        "triples": {
          "defaultHost": [
            0,
            23,
            1119
          ],
          "alidnsUrl": [
            516,
            62,
            1115
          ],
          "fanPrefix": [
            0,
            23,
            1119
          ],
          "domainConfigPath": [
            606,
            37,
            464
          ],
          "userAgent": [
            33,
            247,
            1624
          ]
        }
      },
      "nmyswv-v1": {
        "cls": "Lcom/github/catvod/spider/Nmyswv;",
        "methods": {
          "<init>": [
            "<init>",
            "41d5afbb1822b833adf60a0b0863791c7a675e271c02fa39735abe8622e12416"
          ],
          "init": [
            "init",
            "c127df05c5d69e6f76b7bbfde5831fd62aa24551599f121d1fe36d929c172cd5"
          ],
          "homeContent": [
            "homeContent",
            "1caa1f73d3b482aff950dc9a8d028dc2623526e1e95213c8aae0dc0ec1ed1474"
          ],
          "categoryContent": [
            "categoryContent",
            "0f1fa9082991d30b79dc087ad4a8d8c4be82e545d7e1c6b71f86bec5615c4f27"
          ],
          "detailContent": [
            "detailContent",
            "940b474abce22d695519662b816cffab5ed1d21dc44f88b4d176ef582b16b9cf"
          ],
          "playerContent": [
            "playerContent",
            "dbfa1731bc83a8e16ee46a5ef7ab8fb19f6d3c704e008db6bb3636e34b0ee71d"
          ],
          "searchContent": [
            "searchContent",
            "35bbc5af39fccf310ed256e0d61dbed27346b20607f049801a41c18dbefc237f"
          ]
        },
        "shortArray": [
          "2139d462e5d5739ea643addd222ef6608e9eb0c23154d7913f0ccc290438b3d6",
          "short",
          26,
          893
        ],
        "triples": {
          "defaultHost": [
            0,
            25,
            913
          ]
        }
      },
      "hmys-v1": {
        "cls": "Lcom/github/catvod/spider/Hmys;",
        "methods": {
          "<init>": [
            "<init>",
            "51017d1c5e8e26ce8a9925a0c70888950f35a93b47249daf9048e0ea89ffac63"
          ],
          "init": [
            "init",
            "3481b9dcff123fd5a493bf812446c5ef46d57357eb8a48e2a398853779bcead9"
          ],
          "homeContent": [
            "homeContent",
            "67b6802676a988f7075ec35abcc9ad6992520f64d6aebcac4286d7429e2ae011"
          ],
          "categoryContent": [
            "categoryContent",
            "4dbd4834e6dde8104b1892f0829a25fd8559b5a4e4819f584a3d2d91d140b73e"
          ],
          "detailContent": [
            "detailContent",
            "f31990dceaea0e54319e3f0bfc33c0ff13bb08a71f08dbedfc7aef51de0380f7"
          ],
          "playerContent": [
            "playerContent",
            "94a18c163c77f9487a385788373afa008cb042959ad08b13ac1b7f9ec3425c95"
          ],
          "searchContent": [
            "searchContent",
            "5310a10654c5ad2b3a01cb859a8003e7d9ac944e1ab169e45c099b40b149f4ca"
          ]
        },
        "shortArray": [
          "602182a9f38b276e6743c971e58252b407b70d78463a38dadf18756d44dcb46a",
          "short",
          10,
          2749
        ],
        "triples": {
          "aesKey": [
            0,
            32,
            622
          ],
          "aesIv1": [
            32,
            16,
            2995
          ],
          "aesIv2": [
            48,
            16,
            1166
          ],
          "defaultInitUrl": [
            64,
            36,
            2907
          ],
          "appName": [
            100,
            15,
            2093
          ],
          "channelCode": [
            115,
            9,
            2138
          ],
          "packageName": [
            124,
            5,
            722
          ],
          "signKey": [
            129,
            16,
            1047
          ],
          "v2InitUrl": [
            522,
            43,
            1559
          ],
          "v2Channel": [
            601,
            7,
            3243
          ],
          "v2Pkg": [
            634,
            21,
            3111
          ],
          "v2SignKey": [
            1179,
            32,
            2965
          ],
          "uaOk412": [
            183,
            13,
            2337
          ],
          "uaOk49": [
            196,
            12,
            404
          ]
        }
      },
      "app99-v1": {
        "cls": "Lcom/github/catvod/spider/App99;",
        "methods": {
          "<init>": [
            "<init>",
            "e4b6bfe4015dc5038e939c96a6f56da23afcda1f7f8e5a0f69f706cc1fa28e05"
          ],
          "init": [
            "init",
            "128a234127feadab5bd22fba65ae622abf1f8dd1496d89aa8311bc1a0a810a8a"
          ],
          "homeContent": [
            "homeContent",
            "4b238afd195e656f860ded6898e141cd9932021e361e58e60a9049ba9a728599"
          ],
          "categoryContent": [
            "categoryContent",
            "300af534726dc33acd88a8b110e33eadaef262e48641360860b802d7a6e6c9e5"
          ],
          "detailContent": [
            "detailContent",
            "d42bc67ebc865751bb31d3ddbc0656767b2a0b34d33ca8b74313ba7c1c1dd56a"
          ],
          "playerContent": [
            "playerContent",
            "40bd0c090b0c188ce0f9713484b891b1e611264c9266a94c60bcdc8f03e2c233"
          ],
          "searchContent": [
            "searchContent",
            "0ca6fe78c5416a00d2093185eca506ddd7fc5c9c9cb5c2a255a6b01ed603d432"
          ]
        },
        "shortArray": [
          "fd14de7101c0d310c908a59a60353e8323b174280b0807071ef406ef9d319289",
          "short",
          10,
          1665
        ],
        "triples": {
          "defaultIv": [
            1227,
            16,
            340
          ],
          "userAgent": [
            1290,
            115,
            2285
          ]
        }
      },
      "appsx-v1": {
        "cls": "Lcom/github/catvod/spider/AppSx;",
        "methods": {
          "<init>": [
            "<init>",
            "38fb36e5100bd6e8162e1929fc419f07cba8b8a1faa502077cc50b84e9712a7a"
          ],
          "init": [
            "init",
            "41c437b10467041d8e7a96f0398ba9b65f27b31c2ef4891be96f5f2d722eeb96"
          ],
          "homeContent": [
            "homeContent",
            "2a97c2608cc99bf169e2b0193e1dda87928ab339e6c2d606acb2bc86a210c502"
          ],
          "categoryContent": [
            "categoryContent",
            "b6803144c5250a325c0732097276a35a596edf8bd91a20eff73df3d9b4ed4453"
          ],
          "detailContent": [
            "detailContent",
            "f9c6ff59485fd5a809235550ca4adf1f12b12670d158c22eb39420040a242978"
          ],
          "playerContent": [
            "playerContent",
            "8eb7b7298f23a767a48444b9a6c7bf9680bb54e3a7d627b6c75314eb6302dd0f"
          ],
          "searchContent": [
            "searchContent",
            "b49d56bc7e8326d2f77dbbcbd9c08827d4812d68897c31501757a6aa10af1993"
          ]
        },
        "shortArray": [
          "ad7bc7e5c7c5a90617e10b4d8589e9f18c1a0dba8f7d619a0b0e73dfb241b4b2",
          "short",
          10,
          2283
        ],
        "triples": {
          "defaultVerStr": [
            0,
            3,
            2334
          ],
          "defaultPath": [
            3,
            19,
            2750
          ],
          "qijiPath": [
            1795,
            20,
            1136
          ],
          "vodPath": [
            1815,
            9,
            1668
          ],
          "uaOk310": [
            299,
            13,
            409
          ],
          "uaOk314": [
            312,
            13,
            3019
          ]
        }
      },
      "newcz-v1": {
        "cls": "Lcom/github/catvod/spider/NewCz;",
        "methods": {
          "<init>": [
            "<init>",
            "27f07aa940d293afeacd2d4769d7899c8d53b4728107d48874245b2dd5578ae1"
          ],
          "init": [
            "init",
            "bf6fa734cb832c0aadaee570545df7262f993d7839ea2ebb878e11a3918bbb78"
          ],
          "homeContent": [
            "homeContent",
            "76eb9bcffa8340f1d950596e21c427934971cff3b0bdf647a9ecce9935a586a2"
          ],
          "categoryContent": [
            "categoryContent",
            "a44dfaa28e07af7efc5373b1fbb342d183dab268cc2835854cb917c1eba37a4d"
          ],
          "detailContent": [
            "detailContent",
            "bbda84f5b4b52dc6cc8639f61cd9ce90d892f21ebd2900c7e3d19314102eea6b"
          ],
          "playerContent": [
            "playerContent",
            "050b63a7b7d343b80c511c4a4616223c35447cacd72cc3fcb6051eb0608bc0a2"
          ],
          "searchContent": [
            "searchContent",
            "4e1f0267ce6828a1fef040e256bee15ae9ae2772e187a319520fc9d794472efb"
          ]
        },
        "shortArray": [
          "1eca7b32753880177531f3a6c959a3238ece5bb5d4228e9baf6efbefbf70bd7f",
          "short",
          10,
          3150
        ],
        "triples": {
          "defaultHost": [
            0,
            21,
            2785
          ],
          "altHost": [
            21,
            20,
            2669
          ],
          "searchApi": [
            2528,
            46,
            2021
          ],
          "userAgent": [
            2647,
            116,
            1340
          ],
          "playUa": [
            2023,
            117,
            2222
          ],
          "czFunHost": [
            2242,
            25,
            2542
          ],
          "czFunKey": [
            2267,
            16,
            1369
          ],
          "nowwonHost": [
            2191,
            24,
            651
          ],
          "pyHost": [
            2467,
            28,
            752
          ]
        }
      },
      "libvio-v1": {
        "cls": "Lcom/github/catvod/spider/Libvio;",
        "methods": {
          "<init>": [
            "<init>",
            "3d931e349f1c153476f94fc1beb46fbd685ffa8fb2eccf698d1a08b42085619b"
          ],
          "init": [
            "init",
            "f584b07ce8c65ddda198987dc82a42ec6811d63afc0af425cb4facd18832bf88"
          ],
          "homeContent": [
            "homeContent",
            "32754dc5873a60e3fdda2dc4325e7d89cea07ec7413b783e8cdff8bf1dfb3cd8"
          ],
          "categoryContent": [
            "categoryContent",
            "bdf9ace0752a6bad787244fd6cb8980f71703eeb4de5969cd857b67f640a4cf7"
          ],
          "detailContent": [
            "detailContent",
            "16ac48263436bce760a277716d4771cac8ec9a079ba79cf368ed80ee12551b3a"
          ],
          "playerContent": [
            "playerContent",
            "374793570fe65b9aba552d5f84dfd78cf30cc5b3dd0fb9fb3e4850ffbaa7d882"
          ],
          "searchContent": [
            "searchContent",
            "900d8f9512a93993f42ecf9d6217e683260bedca2bfbc11f8d77fc1ef7f5f4a8"
          ]
        },
        "shortArray": [
          "e48ebbe58eee35cc86ce6e8ed5ecd861176ce90d26df7fa424e877c89d8d83b9",
          "short",
          10,
          2012
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            428
          ],
          "headersBlock": [
            210,
            560,
            684
          ],
          "playUa": [
            1606,
            102,
            2000
          ]
        }
      },
      "ygp-v1": {
        "cls": "Lcom/github/catvod/spider/YGP;",
        "methods": {
          "<init>": [
            "<init>",
            "f759f20aa3a0f80e52aa01c6923818a0f82259e6a1f88527f4ec94676a0af0c3"
          ],
          "init": [
            "init",
            "421503b22ed81361b9609fdd516adc0e280c03df02f2ccd0ea764198d1410d1f"
          ],
          "homeContent": [
            "homeContent",
            "027bf1c020489880adab124ed0602e0357162973303e0e8578f52a5f3977819d"
          ],
          "categoryContent": [
            "categoryContent",
            "c49c5bde94f31077f6a6bbff16c2ff72ba95ab6e94b8957bb3a4abaa9ff5fd83"
          ],
          "detailContent": [
            "detailContent",
            "a7459f1731fa4983c9caca697c9f04af555b90f2ae8873f75d670c8cd0e2bb6d"
          ],
          "playerContent": [
            "playerContent",
            "7550b37604adf521e5fe3bc2163d1ce74b8152c6a7ccb17e28cc76d18ee8a96a"
          ],
          "searchContent": [
            "searchContent",
            "5148f370bf7d02d21c14809babceee08f0ce5cf9f3f84dcf4a6ed28ac60f6524"
          ]
        },
        "shortArray": [
          "d007b8bdecd8c4e9fdffc2eee8b8a06b4a0be6826c084e9dfe4916aef155b784",
          "short",
          10,
          1268
        ],
        "triples": {
          "defaultHost": [
            4,
            21,
            466
          ],
          "userAgent": [
            988,
            110,
            3100
          ]
        },
        "literals": {
          "filtersJson": [
            "init",
            "421503b22ed81361b9609fdd516adc0e280c03df02f2ccd0ea764198d1410d1f",
            5
          ]
        }
      },
      "kanqiu-v1": {
        "cls": "Lcom/github/catvod/spider/Kanqiu;",
        "methods": {
          "<init>": [
            "<init>",
            "a378b5b2c389362b434cb33fb3634a1d618bf942ee3b835661184f433e72d39d"
          ],
          "init": [
            "init",
            "c9e42ee27016492ad42acdd6a7ef50d9578596947e8fa2574e23dc6faccae399"
          ],
          "homeContent": [
            "homeContent",
            "b6e8cd74a1a9eada595c498d28093ba9079cbfc9f20c4a0343b894ba09f94c80"
          ],
          "categoryContent": [
            "categoryContent",
            "5bde844a5d06484b0174581b6d0e0ff46a231a9ac64c4d66c569c04aa515f00d"
          ],
          "detailContent": [
            "detailContent",
            "386e87d99deda1a3b797dc38ac7bb51b262e3c6785c75ef03bc230ec6bdb466c"
          ],
          "playerContent": [
            "playerContent",
            "61babe41d2b55c4941b6b30c121a4e9d938355d6e5cde3fb18b499ca09c4146a"
          ]
        },
        "shortArray": [
          "93f14be7fc609ad329d625c0fb79134c397e1518f800fd2f7a309401d9f71c15",
          "short",
          26,
          1224
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            2556
          ],
          "userAgent": [
            32,
            111,
            569
          ],
          "filtersJson": [
            373,
            767,
            2264
          ],
          "xxteaKey": [
            1197,
            24,
            2967
          ]
        }
      },
      "doubao-v1": {
        "cls": "Lcom/github/catvod/spider/Doubao;",
        "methods": {
          "<init>": [
            "<init>",
            "a82c097e3bae8c8a5dc719abcba36114bd44f458604ef7ac909b0dc9ef1e6be4"
          ],
          "homeContent": [
            "homeContent",
            "040a3c4fa0a53b638289813a3308651c61206a49c27a4de2ef478dbd166d8bdf"
          ],
          "categoryContent": [
            "categoryContent",
            "a0b9cc036d45abbfd1cc151b0462752b75ee15b2e6ad3731d413864f49171a5e"
          ],
          "detailContent": [
            "detailContent",
            "3e8c3b20dba22d3e880acf1d06e2fef2b035a970fa770ba12575af5595275fc1"
          ],
          "playerContent": [
            "playerContent",
            "54675e19bca7c2428efdbeb21ae00a0723b7566c0b16b8ac3ae83071678ed9f1"
          ]
        },
        "shortArray": [
          "5bff52d9393842a8cbc3c9974330b430af5acccd3ff98890f1d6b2bdb4da5c1a",
          "short",
          10,
          1411
        ],
        "triples": {
          "defaultHost": [
            0,
            27,
            397
          ],
          "scheduleUrl": [
            27,
            49,
            405
          ],
          "playbackUrl": [
            76,
            44,
            1775
          ],
          "userAgent": [
            120,
            111,
            1300
          ]
        }
      },
      "livegz-v1": {
        "cls": "Lcom/github/catvod/spider/LiveGz;",
        "methods": {
          "<init>": [
            "<init>",
            "63d91843b88e9ae6438377bdd7641b377699f9b77b6f0c3b86ed00a5a4248c25"
          ],
          "init": [
            "init",
            "55474a702ae5f08f2617036d155315db36fa2a25f8bbdd8d722932d67d4e1ede"
          ],
          "homeContent": [
            "homeContent",
            "3861c1d92f1457b40a623318ee0bf104260793d35ce3cd746998fb911744de83"
          ],
          "categoryContent": [
            "categoryContent",
            "f4164eff56a5bc1da7b12c3d58d1dbce3fa013d4812298235d230e29f6e70ac6"
          ],
          "detailContent": [
            "detailContent",
            "52194a67ac645b507caf8ad396703307caf1979d8da81134e8dc13842202eb12"
          ],
          "playerContent": [
            "playerContent",
            "00a8305a4430780e7d1dba260a3cd2e306ca545ee1e4cc426196865028af9b21"
          ],
          "searchContent": [
            "searchContent",
            "6427f7ab92e69d7fe1e00a87364e54747cefb2ff458225043b62b0ba929fed7e"
          ]
        },
        "shortArray": [
          "e72a0b48aa8e5019dd1ed5580bbf852c9e4da408fcffa276b43fd3647b40bf2a",
          "short",
          10,
          540
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            1330
          ],
          "aesKey": [
            169,
            16,
            804
          ],
          "aesIv": [
            185,
            16,
            1669
          ],
          "sportsPath": [
            201,
            29,
            2697
          ],
          "detailPath": [
            367,
            29,
            380
          ],
          "userAgent": [
            240,
            13,
            586
          ],
          "clientVersion": [
            267,
            7,
            2616
          ]
        }
      },
      "alllive-v1": {
        "cls": "Lcom/github/catvod/spider/Alllive;",
        "methods": {
          "<init>": [
            "<init>",
            "cb33c6dbe4ab6261cb76036284f3bd8e1314ba55081ed83a2d096a54763c8327"
          ],
          "init": [
            "init",
            "f56da7ba07090cd3cb53fe161234440d117b86c5a8c60c7161cd41d6faff3568"
          ],
          "homeContent": [
            "homeContent",
            "3ebc5a2b57f72862fc95eec26576d3820b70d4f82073930b7521938d8e28bef3"
          ],
          "categoryContent": [
            "categoryContent",
            "8a4228835f57e8d95396f65433911e370a983fcbfe21d3f84aa60842ea15c01b"
          ],
          "detailContent": [
            "detailContent",
            "66dd9c0e4acde6dfe39909812d6c56414fc54b69e52a85261a1fbaa87dc38257"
          ],
          "playerContent": [
            "playerContent",
            "11e7e5836d5f3832e8d4c31c0d14ab9869dc5dece9323035cd9f4fbcc7caea85"
          ]
        },
        "shortArray": [
          "13bf84c831ae4d07b19defcae1ab51fd986ee8085fc59fbfaa1b879165ff3409",
          "short",
          10,
          1672
        ],
        "triples": {
          "huyaLoginUrl": [
            1486,
            42,
            350
          ],
          "huyaLoginBody": [
            1528,
            64,
            740
          ],
          "huyaBase": [
            1271,
            21,
            2190
          ]
        }
      },
      "yueting-v1": {
        "cls": "Lcom/github/catvod/spider/YueTing;",
        "methods": {
          "<init>": [
            "<init>",
            "c33f37ca96f6febbf33437551c582fb271bf4b1cbbf10cc038513ad6df2a2074"
          ],
          "init": [
            "init",
            "15e72f2fc3fc94f1ed60774daa0e5afd8e8f0197dd88e6df7e74c9c6e74364bd"
          ],
          "homeContent": [
            "homeContent",
            "162d4b853baf4470cc86951389022aad0341438e31820703b9fcab7810678c82"
          ],
          "categoryContent": [
            "categoryContent",
            "aeacdfc9ece2ab11f79349feb5ce13e6200a9eddfe0e685cea7ea9b6135bd499"
          ],
          "detailContent": [
            "detailContent",
            "30358b830480d5297db637e643b2e7ed6443b7feefa25367db065a9c3970d07d"
          ],
          "playerContent": [
            "playerContent",
            "e202d11832eaf114d410cf1ba37f33ab2b55f8a4c8557dc198a81d43ee5467c6"
          ],
          "searchContent": [
            "searchContent",
            "d57c5829a21c84d3c7aa74248fa3917334d2beda2ff508686dba9db0106a1e0b"
          ]
        },
        "literals": {
          "headUrl1": [
            "<clinit>",
            "cc4e58ce72a3da96223e2ef1c1dc428927e6f14e8bbd7123a41469c99fdfaa96",
            0
          ],
          "headUrl2": [
            "<clinit>",
            "cc4e58ce72a3da96223e2ef1c1dc428927e6f14e8bbd7123a41469c99fdfaa96",
            2
          ],
          "fallbackApi1": [
            "<clinit>",
            "cc4e58ce72a3da96223e2ef1c1dc428927e6f14e8bbd7123a41469c99fdfaa96",
            10
          ],
          "fallbackApi2": [
            "<clinit>",
            "cc4e58ce72a3da96223e2ef1c1dc428927e6f14e8bbd7123a41469c99fdfaa96",
            12
          ],
          "browserUa": [
            "<init>",
            "c33f37ca96f6febbf33437551c582fb271bf4b1cbbf10cc038513ad6df2a2074",
            3
          ],
          "apiUa": [
            "yq",
            "0a09c05d1f40d17580f3a6b222437f9d35c50c979cfe48348970e529793629f5",
            7
          ],
          "jsonBase": [
            "categoryContent",
            "aeacdfc9ece2ab11f79349feb5ce13e6200a9eddfe0e685cea7ea9b6135bd499",
            41
          ],
          "albumInfoUrl": [
            "detailContent",
            "30358b830480d5297db637e643b2e7ed6443b7feefa25367db065a9c3970d07d",
            17
          ],
          "albumChaptersUrl": [
            "detailContent",
            "30358b830480d5297db637e643b2e7ed6443b7feefa25367db065a9c3970d07d",
            35
          ],
          "filtersJson": [
            "homeContent",
            "162d4b853baf4470cc86951389022aad0341438e31820703b9fcab7810678c82",
            67
          ],
          "referer": [
            "playerContent",
            "e202d11832eaf114d410cf1ba37f33ab2b55f8a4c8557dc198a81d43ee5467c6",
            2
          ],
          "origin": [
            "playerContent",
            "e202d11832eaf114d410cf1ba37f33ab2b55f8a4c8557dc198a81d43ee5467c6",
            287
          ],
          "searchUrl": [
            "searchContent",
            "eed767828ba4ad177989d107b08ca904250570e89131823b8ae8eeef67fba5f6",
            37
          ]
        },
        "extraLiterals": {
          "keyHex": [
            "Lcom/github/catvod/spider/YueTingCrypto;",
            "<clinit>",
            "b120319956d542120ba6f3294e7ac8f6096f9d7afade4838a6637a207727abbc",
            0
          ]
        }
      },
      "seedhub-v1": {
        "cls": "Lcom/github/catvod/spider/Seedhub;",
        "methods": {
          "<init>": [
            "<init>",
            "882f78a947417dbefdc1d7b00a70426fe9dde5a95918cb6d6f505e57210a11cb"
          ],
          "init": [
            "init",
            "4061d4789faff3e04e9c609319d77d911959e4d8a609663f6bf051c968117300"
          ],
          "homeContent": [
            "homeContent",
            "9506c9acb4414baec228cc03c637bbeb39db2cce4fd3d1f202afbd47ba1c17e5"
          ],
          "categoryContent": [
            "categoryContent",
            "59fb32c265cb3320c514ba2388355715e8bebb41fa9413483c6af796252ad50a"
          ],
          "detailContent": [
            "detailContent",
            "619ffef54f284120f5f04f2597a35f2b90bf601c8306e7d25d5cd33bc7f8b742"
          ],
          "searchContent": [
            "searchContent",
            "4e9d3993b0149e2e1f2a01499be0cea7992cf326ac32be26db07ea5dd593676e"
          ]
        },
        "shortArray": [
          "0b17d52eaeb66c8988fce147d96249bfad3f47aae37ba99a2c963cf179030184",
          "short",
          10,
          1698
        ],
        "triples": {
          "defaultHost": [
            0,
            20,
            2274
          ]
        }
      },
      "szps-v1": {
        "cls": "Lcom/github/catvod/spider/S_zps;",
        "methods": {
          "<init>": [
            "<init>",
            "8877319eb59875e7abfb6508f8aac68cc7adf521f304eaa53d9be420846c0a85"
          ],
          "init": [
            "init",
            "b0672001339c37425216da170aca7d08df50fe4c29a243d9df56c0c20485bc60"
          ],
          "homeContent": [
            "homeContent",
            "198aa7d981e5452995806afd121a807fb274f194f31045fa6680570b0354f82f"
          ],
          "categoryContent": [
            "categoryContent",
            "eee22d06fe7e209a15ff258bb647875d15ac7876c3d36875622a10a7dc4404ae"
          ],
          "searchContent": [
            "searchContent",
            "aae3298ca467e13f549a2b401a2b8438fd11565b3f78d76eb7b9ef06aaa3a2ea"
          ]
        },
        "shortArray": [
          "272a6f9326435b46a10a1a5b5a8dafdf430afcfaccd99fc607cccc6a08f1a733",
          "short",
          10,
          1107
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            399
          ],
          "searchApiPath": [
            22,
            15,
            3161
          ],
          "loginPath": [
            70,
            14,
            1224
          ]
        }
      },
      "ypanso-v1": {
        "cls": "Lcom/github/catvod/spider/YpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "3f1b5c37ff0dcdaf263157f1d0ef66fbd077aa637cb541caba01e69b27af22ac"
          ],
          "homeContent": [
            "homeContent",
            "0f2b8eb1f8ac989b5bf6216ad00f96e2e2e131501dff829f53f736ef5f5a4555"
          ],
          "detailContent": [
            "detailContent",
            "66260eda851945378b59c34233fe728b20ba0b2b0e967f396f064db2272fbc17"
          ],
          "searchContent": [
            "searchContent",
            "178bc005cc29521abf742139b445dc0a1ef92bd41fae632c7458c622b77268e6"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "10b681cd2226d689fad6e90de76ab571468e2796705558f0f03cafaa21ca7494",
            21
          ],
          "origin": [
            "searchContent",
            "10b681cd2226d689fad6e90de76ab571468e2796705558f0f03cafaa21ca7494",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "10b681cd2226d689fad6e90de76ab571468e2796705558f0f03cafaa21ca7494",
            75
          ],
          "searchUrl": [
            "searchContent",
            "10b681cd2226d689fad6e90de76ab571468e2796705558f0f03cafaa21ca7494",
            84
          ]
        }
      },
      "bpanso-v1": {
        "cls": "Lcom/github/catvod/spider/BpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "3f1b5c37ff0dcdaf263157f1d0ef66fbd077aa637cb541caba01e69b27af22ac"
          ],
          "homeContent": [
            "homeContent",
            "0f2b8eb1f8ac989b5bf6216ad00f96e2e2e131501dff829f53f736ef5f5a4555"
          ],
          "detailContent": [
            "detailContent",
            "66260eda851945378b59c34233fe728b20ba0b2b0e967f396f064db2272fbc17"
          ],
          "searchContent": [
            "searchContent",
            "3c2b323a95bf0442d17788062366a7837c9c3d3bc69271d767cc79055d1f991b"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "7819da02e323457a00df3c5eeca60db2dc5816258cb7deac0c9e73f2b6134683",
            21
          ],
          "origin": [
            "searchContent",
            "7819da02e323457a00df3c5eeca60db2dc5816258cb7deac0c9e73f2b6134683",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "7819da02e323457a00df3c5eeca60db2dc5816258cb7deac0c9e73f2b6134683",
            75
          ],
          "searchUrl": [
            "searchContent",
            "7819da02e323457a00df3c5eeca60db2dc5816258cb7deac0c9e73f2b6134683",
            84
          ]
        }
      },
      "kkss-v1": {
        "cls": "Lcom/github/catvod/spider/KkSs;",
        "methods": {
          "<init>": [
            "<init>",
            "0af5fe566d4ef7df8d040b15ce3d98a559990b8c5138be39c11a8242d57d12e3"
          ],
          "init": [
            "init",
            "f0a2f2a9fbb4b723b2dc3ed9a73c2f244ada782ffcb5d6e4668d6b529937eb64"
          ],
          "homeContent": [
            "homeContent",
            "84e770e47857ba5f5d8b74ba2adf266acfdcd79b64ee104e65920e6d645255c0"
          ],
          "detailContent": [
            "detailContent",
            "9fb7b84f7183e5d2edd994ac03cd2688616f2583032d700091414527080c5edd"
          ],
          "searchContent": [
            "searchContent",
            "14f142e00351f230d0c063072a7aa0b929530bb89a35c68030b759819359ce44"
          ]
        },
        "shortArray": [
          "94c613afbb2cb0e211ec89bf44a06b4d4a73473bd5fa5ec4da6009ae3a3d24b4",
          "short",
          10,
          609
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              19,
              1655
            ],
            [
              19,
              20,
              2760
            ],
            [
              39,
              22,
              1037
            ],
            [
              61,
              22,
              1025
            ],
            [
              83,
              19,
              2948
            ],
            [
              102,
              18,
              2779
            ],
            [
              120,
              22,
              3069
            ],
            [
              142,
              21,
              2248
            ]
          ]
        },
        "triples": {
          "detailPath": [
            167,
            24,
            1285
          ]
        }
      },
      "uuss-v1": {
        "cls": "Lcom/github/catvod/spider/UuSs;",
        "methods": {
          "<init>": [
            "<init>",
            "601f0c6eb413c3122f834d3234b2e7a9b64a36477e6db22227c67042d96734c4"
          ],
          "init": [
            "init",
            "0e533b204fefcb49f056ffad46de6c0a3c54317a4e3660e8633da1bcb5c1012b"
          ],
          "homeContent": [
            "homeContent",
            "7a8992a77aed34a38a8207bdaf07d856b17d74a8d386ccd5742f97924ec1ea1a"
          ],
          "detailContent": [
            "detailContent",
            "1a4cc891238ac7c919ec46a9b1f75e972c8e311835abd59560ad15ecc044efa4"
          ],
          "searchContent": [
            "searchContent",
            "29d97fc8f8625bb06c62c36b43526dbe001a90306ea457e17c37e2cc0a74b166"
          ]
        },
        "shortArray": [
          "292dd3bb0304cd15d152614bac5a13f44645b77890e883686ac8453f5a171bcf",
          "short",
          10,
          616
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              22,
              2420
            ],
            [
              22,
              22,
              493
            ],
            [
              44,
              28,
              1101
            ],
            [
              72,
              22,
              1611
            ],
            [
              94,
              19,
              563
            ],
            [
              113,
              21,
              2959
            ],
            [
              134,
              25,
              2122
            ]
          ]
        },
        "triples": {
          "detailPath": [
            163,
            24,
            2161
          ]
        }
      }
    }
  },
  "6f88b2001d45018aad4e7293566ef739be92dee85c123db4cc062539973fe799": {
    "nativeSha": "d5d8adee01e1bdc4c18b445e19ce7c94fb296ca6dce6f18a08786504fc961f01",
    "mask": 21,
    "spiders": {
      "jpys-v1": {
        "cls": "Lcom/github/catvod/spider/Jpys;",
        "methods": {
          "<init>": [
            "<init>",
            "906dd43be73b6315e42c9e61de96563542d466424b2eae82852e4176e352986c"
          ],
          "init": [
            "init",
            "6a598f7ebbae584026b00f926ea3e142bdf8546e7dfc77cee0f5cc548b24c08a"
          ],
          "homeContent": [
            "homeContent",
            "fe615bfe6b0bde165ac0436cc15ae2e3bfd0fb8b093b50624ea8e974a3209f5a"
          ],
          "categoryContent": [
            "categoryContent",
            "f10d2280f5fb8e3ad6f067dab6acb68104bcbcec7d8694a7f8d0e50e9a69a955"
          ],
          "detailContent": [
            "detailContent",
            "3a542041c2ded060345063ac8f8a4f774d4e2f1fa644c93d803ef0e9f444b79e"
          ],
          "playerContent": [
            "playerContent",
            "30c0ec6ea8b304b544d3216de6986da49f2851c3c367354322bb2c893a5dd5d6"
          ],
          "searchContent": [
            "searchContent",
            "2f17f794bd81ff13b60cf089e27700f23d2cc68998c0613d96f29c1ebb145068"
          ]
        },
        "shortArray": [
          "83ace9021a6f90354faf4d07579e843d5bb6d2734748561e01e96c4797fd0a27",
          "short",
          10,
          1191
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            1960
          ],
          "signSuffix": [
            68,
            40,
            1336
          ],
          "userAgent": [
            670,
            102,
            1689
          ]
        }
      },
      "jpj-v1": {
        "cls": "Lcom/github/catvod/spider/JPJ;",
        "methods": {
          "<init>": [
            "<init>",
            "7afcff614e5cee05db8bdf9f5247a5179bfbd982e72b5ab25ee2647f27e63343"
          ],
          "init": [
            "init",
            "827a527921a2268c98b114110ac176e9f48ad25eb40d0d017c7ece88be22aeea"
          ],
          "homeContent": [
            "homeContent",
            "96d99ea9d51928f9c72f64895ce278c12ceb7d233205851e5c47ac4ae0775423"
          ],
          "categoryContent": [
            "categoryContent",
            "b457a73a4490fdf596b1730d3faa229229a26b58e65f87488d3bde83c8146183"
          ],
          "detailContent": [
            "detailContent",
            "236ebaf3af1e988ce8c6881e531d033d688bd99422e32890f0f6589164ae19f4"
          ],
          "playerContent": [
            "playerContent",
            "92af75335726a7c3aff68602eab8251ada560225c73e5267037995c3cad3bf8d"
          ],
          "searchContent": [
            "searchContent",
            "365564d597736694366aafecbfc592d935cb9743f158fc1f066270810f3088dc"
          ]
        },
        "shortArray": [
          "731f9694b48b90d67dcace5dcc96b9a14d2af3dbac339052bfbe55d8511d100a",
          "short",
          10,
          725
        ],
        "triples": {
          "defaultHost": [
            0,
            23,
            2063
          ],
          "alidnsUrl": [
            516,
            62,
            1659
          ],
          "fanPrefix": [
            0,
            23,
            2063
          ],
          "domainConfigPath": [
            606,
            37,
            462
          ],
          "userAgent": [
            33,
            247,
            2914
          ]
        }
      },
      "nmyswv-v1": {
        "cls": "Lcom/github/catvod/spider/Nmyswv;",
        "methods": {
          "<init>": [
            "<init>",
            "523d1471df33d19bb7acf100d482c47a80009235935355505b55f2e6c67d92bd"
          ],
          "init": [
            "init",
            "d6316fa93e1f3936060e11677215df3f95c1e36d6fc0897b11e4d4597764624a"
          ],
          "homeContent": [
            "homeContent",
            "7ef987ce4af446b0999cf5de07a60d2d28ce14ec0173347d5ed3f99bacb0f250"
          ],
          "categoryContent": [
            "categoryContent",
            "b3b7197cbef7565e308f32aee25810a9f3b22d98189509a9cd9b840ec5d02ff7"
          ],
          "detailContent": [
            "detailContent",
            "46bbc7bab12db68fcddf2066b7c021afcd3fd8a7a8ee3c55520e3b5124a8550c"
          ],
          "playerContent": [
            "playerContent",
            "ffb560c149a139fb42d943ec4170e14f2c77e7ecaca3bc46e2930220577e0588"
          ],
          "searchContent": [
            "searchContent",
            "935a52673b12591fd267c0eb5e7145aeba2a57878049a8f7863b30d87d6e8e16"
          ]
        },
        "shortArray": [
          "87279acacb7fea25d1f59a8fd2829cdccf9c792c03af899090f6cb7ad2857aa0",
          "short",
          26,
          893
        ],
        "triples": {
          "defaultHost": [
            0,
            25,
            515
          ]
        }
      },
      "hmys-v1": {
        "cls": "Lcom/github/catvod/spider/Hmys;",
        "methods": {
          "<init>": [
            "<init>",
            "4bc9a333382c44a15ca12e70c0dd27fd9d20ac60071e2874f0c74eb9e70ad1e6"
          ],
          "init": [
            "init",
            "947a7a53f0d3419f601a3bca443bd575e9db8a0ecbcd701c97bc7b60f20de272"
          ],
          "homeContent": [
            "homeContent",
            "724d1c2488b3197371824fd7e9fec2f938e7463232f6b237fd0aa2f9e93f16f9"
          ],
          "categoryContent": [
            "categoryContent",
            "13c30dfc01f8d4aabcdeaecf7ff1cd47b0b0d21bfd1d426e18a8568b2d158855"
          ],
          "detailContent": [
            "detailContent",
            "135466a77e4067db9e5caeba0cc90284c1a7927805b04ee037e553c75c4dab20"
          ],
          "playerContent": [
            "playerContent",
            "a66743bc3cd9c7717d8168a26073dabda90dddc7919bdc9e923eff5271efd81c"
          ],
          "searchContent": [
            "searchContent",
            "4b495b0ba2882c9532996e7b15be041344e4874f8a25f8f0a8318107829ceeb0"
          ]
        },
        "shortArray": [
          "1ecb496e50dc8fd29f65bcd0b5125e0ed62f4344ff2c76a395f96d042bb54c56",
          "short",
          10,
          2755
        ],
        "triples": {
          "aesKey": [
            0,
            32,
            2192
          ],
          "aesIv1": [
            32,
            16,
            1066
          ],
          "aesIv2": [
            48,
            16,
            1835
          ],
          "defaultInitUrl": [
            64,
            43,
            2386
          ],
          "appName": [
            107,
            11,
            2176
          ],
          "channelCode": [
            118,
            7,
            3086
          ],
          "packageName": [
            125,
            5,
            499
          ],
          "signKey": [
            130,
            21,
            2130
          ],
          "v2InitUrl": [
            64,
            43,
            2386
          ],
          "v2Channel": [
            607,
            7,
            1564
          ],
          "v2Pkg": [
            640,
            21,
            2214
          ],
          "v2SignKey": [
            151,
            32,
            736
          ],
          "uaOk412": [
            189,
            13,
            2278
          ],
          "uaOk49": [
            202,
            12,
            1168
          ]
        }
      },
      "newcz-v1": {
        "cls": "Lcom/github/catvod/spider/NewCz;",
        "methods": {
          "<init>": [
            "<init>",
            "52eefe15b7ee72f2cca52d2cc05848bc44c4c8460f5bc6a356fc93843549d144"
          ],
          "init": [
            "init",
            "2da3474a9e38ca7fcc1ad4518de65b96ad9c646c6336333e2f11c9dcebe9d2f9"
          ],
          "homeContent": [
            "homeContent",
            "b15b6bf45604b76986d0c9296d5483360e9b4dd836a12a821ea23cdcdc6662b4"
          ],
          "categoryContent": [
            "categoryContent",
            "a32c748bc0a58504319290265a0d471ed6a367b1dab663836174a14ea2754ae9"
          ],
          "detailContent": [
            "detailContent",
            "77a30cb998f2c8dfc83fb6cef4383d54a3640ee3617a22793e95adc638e43159"
          ],
          "playerContent": [
            "playerContent",
            "3c3dcd52a5faa4b7e441003794b0677b1dddf5940cb8e22b251bdc3e691cc2cb"
          ],
          "searchContent": [
            "searchContent",
            "c19e03187cfd45046228beec81632d0ae7686defae4e22620efa7dae019a0e96"
          ]
        },
        "shortArray": [
          "2c0360658b9794f689eb69fc76e7cb1844f1708ef46f5de3d0794324219b74aa",
          "short",
          10,
          3150
        ],
        "triples": {
          "defaultHost": [
            0,
            21,
            2176
          ],
          "altHost": [
            21,
            20,
            1190
          ],
          "searchApi": [
            2528,
            46,
            1968
          ],
          "userAgent": [
            2647,
            116,
            851
          ],
          "playUa": [
            2023,
            117,
            2468
          ],
          "czFunHost": [
            2242,
            25,
            678
          ],
          "czFunKey": [
            2267,
            16,
            2887
          ],
          "nowwonHost": [
            2191,
            24,
            1344
          ],
          "pyHost": [
            2467,
            28,
            864
          ]
        }
      },
      "libvio-v1": {
        "cls": "Lcom/github/catvod/spider/Libvio;",
        "methods": {
          "<init>": [
            "<init>",
            "dc07f6c9914414039387fe69ca54db06eab7742d45623c87d116df5261ca87f5"
          ],
          "init": [
            "init",
            "328a0d50fe9ba685dd3053a4a47d3daec98f3d886feb47beb2756208aad5abab"
          ],
          "homeContent": [
            "homeContent",
            "fab6ca5fe639182d75735ad15065c40be3f09405a194a24a58953c42c5ad4eb3"
          ],
          "categoryContent": [
            "categoryContent",
            "38569085e5f016316f644d22af91b32329418b1db5ff7f9dc3a4b187ff51b086"
          ],
          "detailContent": [
            "detailContent",
            "10e329e82a69758305adcbd07de2e798e3509720bb7e1181556fe45ca2acdf10"
          ],
          "playerContent": [
            "playerContent",
            "e1043834cdc5ca5491a808c0101b479c656d06e6d4e76e30b022b841697acf21"
          ],
          "searchContent": [
            "searchContent",
            "38a5bae9e963fd15afa7573c31c394a070a627dd35a44b1bf0152358ab5708f3"
          ]
        },
        "shortArray": [
          "ca079f86a3ad13e82d42bb0de8de54527cef50f54ce221ac54de16cefa74331f",
          "short",
          10,
          2012
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            2958
          ],
          "headersBlock": [
            210,
            560,
            1893
          ],
          "playUa": [
            1606,
            102,
            685
          ]
        }
      },
      "ygp-v1": {
        "cls": "Lcom/github/catvod/spider/YGP;",
        "methods": {
          "<init>": [
            "<init>",
            "7e3e39a107bf52d8e1b500b11da59e0a289427970d645bd277a286bbc9b0314e"
          ],
          "init": [
            "init",
            "c8eb946b731f41f837dd35689a99cd550868281bcebbeb753e4c0e48941950c0"
          ],
          "homeContent": [
            "homeContent",
            "c58c45d23ab65ccf152f153ee239a543b430739fa7ec65a4aaa916b87b0394f1"
          ],
          "categoryContent": [
            "categoryContent",
            "854622e620e9ff6ce17032f07150fbcae0a54774550d01820a021edc799febf5"
          ],
          "detailContent": [
            "detailContent",
            "a4351f200d5c57f94c915e75cc0a143a3608db72b1e28aee7e79acbdc3ddb7b4"
          ],
          "playerContent": [
            "playerContent",
            "729bd48fa94ddfa8506f8eb6935c3112314aa7cc67ddaa96671f64aa240ee404"
          ],
          "searchContent": [
            "searchContent",
            "016fd42ce5e6caf5ee2d85025173ec5b12861591b33fe53dba77689a90be1d7b"
          ]
        },
        "shortArray": [
          "dfc72977e5ac3c31b404024ebf21c4a9db74e7b00344d2eec51c93d70e7091b8",
          "short",
          10,
          1268
        ],
        "triples": {
          "defaultHost": [
            4,
            21,
            2548
          ],
          "userAgent": [
            988,
            110,
            1171
          ]
        },
        "literals": {
          "filtersJson": [
            "init",
            "c8eb946b731f41f837dd35689a99cd550868281bcebbeb753e4c0e48941950c0",
            5
          ]
        }
      },
      "kanqiu-v1": {
        "cls": "Lcom/github/catvod/spider/Kanqiu;",
        "methods": {
          "<init>": [
            "<init>",
            "5d785d867a931c7edfa4874bd716860bad2d3c61042ecc07b7a85e0364c5c840"
          ],
          "init": [
            "init",
            "704e3bbe953bbd14bc6a2c59d9d03b2f7e19a5f72e46d7eaae43f2681c0fef75"
          ],
          "homeContent": [
            "homeContent",
            "dbbb679e1c766a78bf322d68375d16a5f65067a4919185357fd43364baf17723"
          ],
          "categoryContent": [
            "categoryContent",
            "5cc743f654ebb5a22eca445ede30989cc0a88a2207b3ded084491f512ef4eb42"
          ],
          "detailContent": [
            "detailContent",
            "5a9cef127fa442a655cb861008e9b69370790d1ea8a0433be10d6cddc7a270d1"
          ],
          "playerContent": [
            "playerContent",
            "8a7cdc950e102cc0d028c05046f067679ef7567a82d76ff36dee0278abebd6a5"
          ]
        },
        "shortArray": [
          "8d10ae52bf7776406090fc5ddfcfdc4adf45ef9b292c7a673a1e590401ea45dd",
          "short",
          26,
          1224
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            1893
          ],
          "userAgent": [
            32,
            111,
            826
          ],
          "filtersJson": [
            373,
            767,
            1702
          ],
          "xxteaKey": [
            1197,
            24,
            2743
          ]
        }
      },
      "doubao-v1": {
        "cls": "Lcom/github/catvod/spider/Doubao;",
        "methods": {
          "<init>": [
            "<init>",
            "44b3a1dbf7023ba8bce022040f3b7bf4adf710a3f46b22df296df784602eb990"
          ],
          "homeContent": [
            "homeContent",
            "5332c8874bc44790944b90f8d453f88ff6b3a0ba96142bf97e78c0b6eec1f082"
          ],
          "categoryContent": [
            "categoryContent",
            "317763da884612a0f3fc627cf4a0fd0a1de56c7b264e7cd128259e8a4aefccab"
          ],
          "detailContent": [
            "detailContent",
            "93f6da16873d7d92ad54ed9b29965250fc37d9cabce3e279a86a216002e67fa3"
          ],
          "playerContent": [
            "playerContent",
            "822acc244db7407ba3cf650daf033d72c12b91fc39ac382a0110bc216dda6939"
          ]
        },
        "shortArray": [
          "a6eb2e67f12538b450ab05be9d172931ffc57ea3309b1e5ea903428957cb1c19",
          "short",
          10,
          1411
        ],
        "triples": {
          "defaultHost": [
            0,
            27,
            369
          ],
          "scheduleUrl": [
            27,
            49,
            419
          ],
          "playbackUrl": [
            76,
            44,
            1513
          ],
          "userAgent": [
            120,
            111,
            1574
          ]
        }
      },
      "livegz-v1": {
        "cls": "Lcom/github/catvod/spider/LiveGz;",
        "methods": {
          "<init>": [
            "<init>",
            "7b1b68005c366e30e50ca97c229da62fd0139daff3c75c4970c83fec069c5efd"
          ],
          "init": [
            "init",
            "54713a6f98c94b5f907fd0d9ceb4f34f4ba60c920cee8fbc0c86409e24e0031f"
          ],
          "homeContent": [
            "homeContent",
            "26e55a4b51b17dd2a55c90082e7bee61ad8be40200ccac704da826eecc47017c"
          ],
          "categoryContent": [
            "categoryContent",
            "3208e5955475e52237ba871434b3a23c1df1df9f78575927b6d07381caaa944c"
          ],
          "detailContent": [
            "detailContent",
            "d0000c08992df1e28d0cfe8b95a22b2df5200d9c6832514035ea2994aa78b327"
          ],
          "playerContent": [
            "playerContent",
            "011ab1f9900d5ea4054456767938e65b63ecc8fe228446ca51e1d74469bce0f0"
          ],
          "searchContent": [
            "searchContent",
            "594912408dd0e398fbec485f69fe9937f14254ced9249ad5aa22ab76393c7206"
          ]
        },
        "shortArray": [
          "53c5184815449d1a57a67716197115a93eb44784fc9f8843711895ef8d954bd2",
          "short",
          10,
          540
        ],
        "triples": {
          "defaultHost": [
            0,
            24,
            979
          ],
          "aesKey": [
            169,
            16,
            2670
          ],
          "aesIv": [
            185,
            16,
            408
          ],
          "sportsPath": [
            201,
            29,
            1037
          ],
          "detailPath": [
            367,
            29,
            1321
          ],
          "userAgent": [
            240,
            13,
            474
          ],
          "clientVersion": [
            267,
            7,
            2368
          ]
        }
      },
      "alllive-v1": {
        "cls": "Lcom/github/catvod/spider/Alllive;",
        "methods": {
          "<init>": [
            "<init>",
            "c472930b1e88625aafdd70ae405074b7430745d767e0fd866e0b6d3f724a5f5e"
          ],
          "init": [
            "init",
            "3826d9ad8719a2fc4c873edecadaf572b66f040a55d35c60b4d05197e96d2b6e"
          ],
          "homeContent": [
            "homeContent",
            "f4a55ffd058e5cd478d1b58c005bfa2ba91954a141c5100a22cfb4ec50f9cd67"
          ],
          "categoryContent": [
            "categoryContent",
            "361c0b6848bc71b091a04b2ca00eb16c79375b04ad9a325b9b17b41753b447b7"
          ],
          "detailContent": [
            "detailContent",
            "248aaca9eecf55984ee43290404a8dffcc6cb6eda50ed1859939477be525b4d8"
          ],
          "playerContent": [
            "playerContent",
            "4d8b8278ac4204fe6cebe988f931a68abd496f65be7fe6c23ded1b057307491e"
          ]
        },
        "shortArray": [
          "8c3d9573b98bd995cf7e758b2068e3984e78dbe99a4820786a4508ff39dae344",
          "short",
          10,
          1665
        ],
        "triples": {
          "huyaLoginUrl": [
            1479,
            42,
            2358
          ],
          "huyaLoginBody": [
            1521,
            64,
            2028
          ],
          "huyaBase": [
            1264,
            21,
            3136
          ]
        }
      },
      "yueting-v1": {
        "cls": "Lcom/github/catvod/spider/YueTing;",
        "methods": {
          "<init>": [
            "<init>",
            "13a7161e52d89eeb590a83bee97665a840717bf9bd76a69bade383298ee40cdd"
          ],
          "init": [
            "init",
            "cd8a77076318ba0a873c42f9ee99fbf671e221f42fe827bb53443cf5beaea434"
          ],
          "homeContent": [
            "homeContent",
            "ab2b1c1d4a33365aae949c3ed3478e65c4bf1f1d62f9bccb7e6cfb8549cf133c"
          ],
          "categoryContent": [
            "categoryContent",
            "634f11c998982d9b8d91c156e603d5a15f062f5ba777922ca5761f3368988bee"
          ],
          "detailContent": [
            "detailContent",
            "6a4ad278f06168200991ded1c96066c26856b639b39ef158258382dcbd50aa66"
          ],
          "playerContent": [
            "playerContent",
            "d57ee1155d165321b59d9ce80e9f47d87636d50856012b88fc1d434f49f21f8c"
          ],
          "searchContent": [
            "searchContent",
            "d6c5445b74738800d44ee6235722ee584a52def50053b7f9156ff74f3a123479"
          ]
        },
        "literals": {
          "headUrl1": [
            "<clinit>",
            "2b71e80960abc42b0c36e8964fc58203d5c32102900d0a480ff55aa7c4642362",
            0
          ],
          "headUrl2": [
            "<clinit>",
            "2b71e80960abc42b0c36e8964fc58203d5c32102900d0a480ff55aa7c4642362",
            2
          ],
          "fallbackApi1": [
            "<clinit>",
            "2b71e80960abc42b0c36e8964fc58203d5c32102900d0a480ff55aa7c4642362",
            10
          ],
          "fallbackApi2": [
            "<clinit>",
            "2b71e80960abc42b0c36e8964fc58203d5c32102900d0a480ff55aa7c4642362",
            12
          ],
          "browserUa": [
            "<init>",
            "13a7161e52d89eeb590a83bee97665a840717bf9bd76a69bade383298ee40cdd",
            3
          ],
          "apiUa": [
            "yq",
            "6014d46dd4fc49fe1af630cfdc420e4ab10f04ef16c3e6c2a345f667e8898294",
            7
          ],
          "jsonBase": [
            "categoryContent",
            "634f11c998982d9b8d91c156e603d5a15f062f5ba777922ca5761f3368988bee",
            41
          ],
          "albumInfoUrl": [
            "detailContent",
            "6a4ad278f06168200991ded1c96066c26856b639b39ef158258382dcbd50aa66",
            17
          ],
          "albumChaptersUrl": [
            "detailContent",
            "6a4ad278f06168200991ded1c96066c26856b639b39ef158258382dcbd50aa66",
            35
          ],
          "filtersJson": [
            "homeContent",
            "ab2b1c1d4a33365aae949c3ed3478e65c4bf1f1d62f9bccb7e6cfb8549cf133c",
            67
          ],
          "referer": [
            "playerContent",
            "d57ee1155d165321b59d9ce80e9f47d87636d50856012b88fc1d434f49f21f8c",
            2
          ],
          "origin": [
            "playerContent",
            "d57ee1155d165321b59d9ce80e9f47d87636d50856012b88fc1d434f49f21f8c",
            287
          ],
          "searchUrl": [
            "searchContent",
            "1616b884182db16e1ed831e8e88f3b346e73455f149b3d3caf05266dc0d7559b",
            37
          ]
        },
        "extraLiterals": {
          "keyHex": [
            "Lcom/github/catvod/spider/YueTingCrypto;",
            "<clinit>",
            "3df4a15c8a11370fe325ecbc7e3dcf2c27b6149fd9b720338ea891c25d65f21f",
            0
          ]
        }
      },
      "seedhub-v1": {
        "cls": "Lcom/github/catvod/spider/Seedhub;",
        "methods": {
          "<init>": [
            "<init>",
            "662dcbc035fc27d1ef6dea4d4804b501a4c5f7cfbe6f48b8a17e69b8b5af9511"
          ],
          "init": [
            "init",
            "6a00775ddd1a2fcf47bc12170ea036de35b348410eb132586f39b5d7a17be204"
          ],
          "homeContent": [
            "homeContent",
            "0facdb0bd792daf0c27ef6517cbeb82fd8c0c27b91a581da41ee4e6e319c2225"
          ],
          "categoryContent": [
            "categoryContent",
            "43d5490b6424ed07244da9d66423916c0d0c6553f97c7fa88ff5f738af4a3dd0"
          ],
          "detailContent": [
            "detailContent",
            "d9a28e2a5c8ae30c47b81cdd3f5df63ba132559c29998bdbbbbe0090c4c4fe37"
          ],
          "searchContent": [
            "searchContent",
            "ab1ad687e4905672079d2e3cef5fe3066e06d87965efc84498164ffcda893720"
          ]
        },
        "shortArray": [
          "00f674d2d73f9ba5fd74198c8234e390014b645b6b67849e04818c0f8b801c11",
          "short",
          10,
          1696
        ],
        "triples": {
          "defaultHost": [
            0,
            18,
            673
          ]
        }
      },
      "szps-v1": {
        "cls": "Lcom/github/catvod/spider/S_zps;",
        "methods": {
          "<init>": [
            "<init>",
            "1c51fd5dc5a6db92a25657335d57a8e1a4431fcef5d1807fa3ceb4d63e54ab58"
          ],
          "init": [
            "init",
            "9a3253e6059759c7c57ed2af81f2bd2210980373dc4f03823f2f65d3c0a54f71"
          ],
          "homeContent": [
            "homeContent",
            "30a881c847d6482bd320a6974b4b02d839347b49bb0eb026bbe9a4ff246c61df"
          ],
          "categoryContent": [
            "categoryContent",
            "928f5160662445e13ae0d2655527dc6eedff31879fa3a4e1368fac08c6211747"
          ],
          "searchContent": [
            "searchContent",
            "9170a3093adaa6111b8c8f19c52b93c7f8a83754ad57443f415e0a68fe4f2923"
          ]
        },
        "shortArray": [
          "e228a97014ace36b4644897ba9c88cfc4425d6d40fa8f860eb64dace4e6788a4",
          "short",
          10,
          1107
        ],
        "triples": {
          "defaultHost": [
            0,
            22,
            3011
          ],
          "searchApiPath": [
            22,
            15,
            845
          ],
          "loginPath": [
            70,
            14,
            795
          ]
        }
      },
      "ypanso-v1": {
        "cls": "Lcom/github/catvod/spider/YpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "7df2ac0e71f58238f30ad3da07ea50a3842262445a4efcc6135f37b6863eaa4b"
          ],
          "homeContent": [
            "homeContent",
            "5789d8111cb473b8d58108735e1dbc3bc000a962ce52a2fca9d4090e1a3d6b8f"
          ],
          "detailContent": [
            "detailContent",
            "b6d005d844e8b77d12c39a6be076343890b5f6cd4d85c95e10f34e9ac8dc8cbb"
          ],
          "searchContent": [
            "searchContent",
            "e3580e1fc04c1689d96178e71aa4191c5ff63d1abc49d8c8cbcb2a545905a5b0"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "74f91e726bf2bb03bdaebd922f69c708edb1bbd8b2d04d6cb0a694e2a2ba6435",
            21
          ],
          "origin": [
            "searchContent",
            "74f91e726bf2bb03bdaebd922f69c708edb1bbd8b2d04d6cb0a694e2a2ba6435",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "74f91e726bf2bb03bdaebd922f69c708edb1bbd8b2d04d6cb0a694e2a2ba6435",
            75
          ],
          "searchUrl": [
            "searchContent",
            "74f91e726bf2bb03bdaebd922f69c708edb1bbd8b2d04d6cb0a694e2a2ba6435",
            84
          ]
        }
      },
      "bpanso-v1": {
        "cls": "Lcom/github/catvod/spider/BpanSo;",
        "methods": {
          "<init>": [
            "<init>",
            "7df2ac0e71f58238f30ad3da07ea50a3842262445a4efcc6135f37b6863eaa4b"
          ],
          "homeContent": [
            "homeContent",
            "5789d8111cb473b8d58108735e1dbc3bc000a962ce52a2fca9d4090e1a3d6b8f"
          ],
          "detailContent": [
            "detailContent",
            "b6d005d844e8b77d12c39a6be076343890b5f6cd4d85c95e10f34e9ac8dc8cbb"
          ],
          "searchContent": [
            "searchContent",
            "255df0cc63892885613d9a30571e4c0c86e9b3abde9d8dfefc3e80c91cf4085c"
          ]
        },
        "literals": {
          "referer": [
            "searchContent",
            "bdd05d9c9883740d36caa40e0fa73f6201804b2c5790c70cfabcefd8222b688e",
            21
          ],
          "origin": [
            "searchContent",
            "bdd05d9c9883740d36caa40e0fa73f6201804b2c5790c70cfabcefd8222b688e",
            44
          ],
          "bodySuffix": [
            "searchContent",
            "bdd05d9c9883740d36caa40e0fa73f6201804b2c5790c70cfabcefd8222b688e",
            75
          ],
          "searchUrl": [
            "searchContent",
            "bdd05d9c9883740d36caa40e0fa73f6201804b2c5790c70cfabcefd8222b688e",
            84
          ]
        }
      },
      "kkss-v1": {
        "cls": "Lcom/github/catvod/spider/KkSs;",
        "methods": {
          "<init>": [
            "<init>",
            "a781fe21911be767e2b156618c74db6110912eafc25a7cce88fc5a64298f9c05"
          ],
          "init": [
            "init",
            "69ee66097103b378c0635ae0b5df45264e55717ecb7b587f7a3f75ee8346ebee"
          ],
          "homeContent": [
            "homeContent",
            "98980ff52df5d210309b26b29c71f00b2c1d18cb479e70853385464c3dbfec4c"
          ],
          "detailContent": [
            "detailContent",
            "8bcb3bd4df0db8dafd32934e15e1e43e4dae992362929866a94c7b1c71f4a330"
          ],
          "searchContent": [
            "searchContent",
            "08be867fa968e7465e56bfda70adeee8711431e62fd39eb915e5edb14d92afa2"
          ]
        },
        "shortArray": [
          "2bec23ba5c0ac21ba8fbeadfce4fed0ced00476b60ce6a6cd1a57cc8cfa01c0e",
          "short",
          10,
          609
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              19,
              2312
            ],
            [
              19,
              20,
              3063
            ],
            [
              39,
              22,
              1735
            ],
            [
              61,
              22,
              1271
            ],
            [
              83,
              19,
              3053
            ],
            [
              102,
              18,
              1863
            ],
            [
              120,
              22,
              1389
            ],
            [
              142,
              21,
              3218
            ]
          ]
        },
        "triples": {
          "detailPath": [
            167,
            24,
            2222
          ]
        }
      },
      "uuss-v1": {
        "cls": "Lcom/github/catvod/spider/UuSs;",
        "methods": {
          "<init>": [
            "<init>",
            "a05d44f2f6ce777a635fce4f39adf5b76d025b108fd5b66a9e7735f8b4dce652"
          ],
          "init": [
            "init",
            "31ac733e0432c77056f1ffe02ec5e64676f9dd505668f3284f2c24dd29284f9f"
          ],
          "homeContent": [
            "homeContent",
            "1648fbed90d31eb718c75d84fd2f11e65b1a19a777837a1ad7bc420bcf1a8c4b"
          ],
          "detailContent": [
            "detailContent",
            "d3eb8267da94734fb076d8217eb7c2ca8a1ab68dd7dc6d82b5198769785f986d"
          ],
          "searchContent": [
            "searchContent",
            "deccd7c1dccba3c78e911febff5fd4911d70e464eed318c98a8420f953d02aba"
          ]
        },
        "shortArray": [
          "2cc7e93349b55120aceeb67237219833070d1102f0a19db14a9c0fb5a35f0823",
          "short",
          10,
          616
        ],
        "tripleLists": {
          "sites": [
            [
              0,
              22,
              639
            ],
            [
              22,
              22,
              2548
            ],
            [
              44,
              28,
              1096
            ],
            [
              72,
              22,
              2144
            ],
            [
              94,
              19,
              1975
            ],
            [
              113,
              21,
              1414
            ],
            [
              134,
              25,
              1105
            ]
          ]
        },
        "triples": {
          "detailPath": [
            163,
            24,
            3264
          ]
        }
      }
    }
  }
};

const fail = () => { throw Error('guard_artifact_invalid'); };
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

function parseHttpOrigin(raw) {
  if (typeof raw !== 'string' || !raw) fail();
  const text = raw.trim();
  if (!text || text.length > 2048 || /[\x00-\x20\x7f\\]/.test(text)) fail();
  let url;
  try { url = new URL(text); } catch (_) { fail(); }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || !url.hostname || url.username || url.password) fail();
  return url.origin;
}

function decodeExtension(rawExt, key) {
  if (rawExt === undefined || rawExt === null) return '';
  if (typeof rawExt !== 'string' || Buffer.byteLength(rawExt) > 16 * 1024) fail();
  const trimmed = rawExt.trim();
  if (!trimmed) return '';
  if (trimmed.startsWith('{') || trimmed.startsWith('[') || /^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  if (trimmed.startsWith('fty_0_0_')) {
    return decodeShiftedExt(trimmed.slice(8), key).trim();
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
    try {
      const shifted = decodeShiftedExt(normalized, key).trim();
      if (shifted) return shifted;
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

function resolveOrigin(adapter, extracted, extText, extObj) {
  const candidates = [];
  if (typeof extObj.host === 'string' && /^https?:\/\//i.test(extObj.host.trim())) candidates.push(extObj.host.trim());
  if (typeof extObj.url === 'string' && /^https?:\/\//i.test(extObj.url.trim())) candidates.push(extObj.url.trim());
  if (typeof extObj.siteUrl === 'string' && /^https?:\/\//i.test(extObj.siteUrl.trim())) candidates.push(extObj.siteUrl.trim());
  if (typeof extObj.api === 'string' && /^https?:\/\//i.test(extObj.api.trim())) candidates.push(extObj.api.trim());
  if (typeof extObj.tokenUrl === 'string' && /^https?:\/\//i.test(extObj.tokenUrl.trim())) candidates.push(extObj.tokenUrl.trim());
  if (typeof extObj.domain === 'string') {
    for (const part of extObj.domain.split(/[|,;\s]+/)) {
      if (/^https?:\/\//i.test(part.trim())) candidates.push(part.trim());
    }
  }
  if (/^https?:\/\//i.test(extText)) {
    const first = extText.split(/[|,;\s]+/)[0];
    if (first) candidates.push(first);
  }
  if (typeof extracted.origin === 'string' && /^https?:\/\//i.test(extracted.origin)) candidates.push(extracted.origin);
  if (typeof extracted.defaultHost === 'string' && /^https?:\/\//i.test(extracted.defaultHost)) candidates.push(extracted.defaultHost);
  if (typeof extracted.defaultInitUrl === 'string' && /^https?:\/\//i.test(extracted.defaultInitUrl)) candidates.push(extracted.defaultInitUrl);
  if (typeof extracted.jsonBase === 'string' && /^https?:\/\//i.test(extracted.jsonBase)) candidates.push(extracted.jsonBase);
  if (typeof extracted.huyaBase === 'string' && /^https?:\/\//i.test(extracted.huyaBase)) candidates.push(extracted.huyaBase);
  if (Array.isArray(extracted.sites)) {
    for (const s of extracted.sites) if (/^https?:\/\//i.test(s)) candidates.push(s);
  }
  for (const c of candidates) {
    try { return parseHttpOrigin(c); } catch (_) {}
  }
  fail();
}

function extractFty(bytes, adapter, rawExtension) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX) fail();
  if (!FTY_ADAPTERS.includes(adapter)) fail();
  const profile = PROFILES[sha(bytes)];
  if (!profile) throw Error('guard_artifact_unsupported');
  const native = zipMember(bytes, 'assets/ftyguard_v8.so');
  if (native.length !== 102440 || sha(native) !== profile.nativeSha) throw Error('guard_artifact_integrity');
  const spec = profile.spiders[adapter];
  if (!spec) throw Error('guard_artifact_unsupported');
  const key = elfBytes(native, 0x19198, 13).map(v => v ^ profile.mask);
  const extText = decodeExtension(rawExtension, key);
  const extObj = parseExtObject(extText);

  const budget = { bytes: 0, entries: 0 };
  const dex = new Dex(zipMember(unwrapGuard(zipMember(bytes, 'assets/ftyshinidie.guard', budget)), 'classes.dex', budget));
  for (const [, [methodName, expectedHash]] of Object.entries(spec.methods)) {
    dex.reviewedCodeByHash(spec.cls, methodName, expectedHash);
  }

  const extracted = {};
  if (spec.shortArray) {
    const [clinitHash, fieldName, payloadUnit, count] = spec.shortArray;
    const values = dex.reviewedShortArray(spec.cls, clinitHash, fieldName, payloadUnit, count);
    const decode = ([start, length, maskVal]) => String.fromCharCode(...values.slice(start, start + length).map(v => v ^ maskVal));
    if (spec.triples) {
      for (const [k, triple] of Object.entries(spec.triples)) {
        extracted[k] = decode(triple);
      }
    }
    if (spec.tripleLists) {
      for (const [k, list] of Object.entries(spec.tripleLists)) {
        extracted[k] = list.map(decode);
      }
    }
  }
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

  const origin = resolveOrigin(adapter, extracted, extText, extObj);
  return {
    adapter,
    origin,
    extText,
    ext: extObj,
    ...extracted
  };
}

module.exports = { FTY_ADAPTERS, extractFty, decodeExtension };
