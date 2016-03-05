express   = require 'express'
co        = require 'co'
_         = require 'underscore'
moment    = require 'moment'
debug     = require 'debug'
rongCloud = require 'rongcloud-sdk'
qiniu     = require 'qiniu'

Config    = require '../conf'
Utility   = require('../util/util').Utility
APIResult = require('../util/util').APIResult

# 引用数据库对象和模型
[sequelize, User, Blacklist, Friendship, Group, GroupMember, GroupSync, DataVersion, VerificationCode, LoginLog] = require '../db'

NICKNAME_MIN_LENGTH = 1
NICKNAME_MAX_LENGTH = 32

PORTRAIT_URI_MIN_LENGTH = 12
PORTRAIT_URI_MAX_LENGTH = 256

PASSWORD_MIN_LENGTH = 6
PASSWORD_MAX_LENGTH = 20

log = debug 'app:log'
logError = debug 'app:error'

# 初始化融云 Server API SDK
rongCloud.init Config.RONGCLOUD_APP_KEY, Config.RONGCLOUD_APP_SECRET

router = express.Router()

validator = sequelize.Validator

# 国际电话区号和国家代码对应关系
regionMap =
  '86' : 'zh-CN'

checkPhoneAvailable = (region, phone) ->
  User.count
    where:
      region: region
      phone: phone
  .then (count) ->
    Promise.resolve count is 0
  .catch (error) ->
    Promise.reject error

# checkUsernameAvailable = (username) ->
#   User.count
#     where:
#       username: username
#   .then (count) ->
#     Promise.resolve count is 0
#   .catch (error) ->
#     Promise.reject error

getToken = (userId, nickname, portraitUri) ->
  new Promise (resolve, reject) ->
    # 强制获取新 Token 或者数据库中没有缓存 Token 则调用 Server API SDK 获取 Token
    rongCloud.user.getToken Utility.encodeId(userId), nickname, portraitUri, (err, resultText) ->
      if err
        return reject err

      result = JSON.parse resultText

      if result.code isnt 200
        return reject new Error 'RongCloud Server API Error Code: ' + result.code

      # 更新到数据库
      User.update
        rongCloudToken: result.token
      ,
        where:
          id: userId
      .then ->
        resolve result.token
      .catch (error) ->
        reject error

# 发送验证码
router.post '/send_code', (req, res, next) ->
  region = req.body.region
  phone  = req.body.phone
  # 如果在融云开发者后台开启图形验证码，需要校验 verify_id 和 verify_code。
  # verify_id   = req.body.verify_id
  # verify_code = req.body.verify_code

  # 如果不是合法的手机号，直接返回，省去查询数据库的步骤
  if not validator.isMobilePhone phone, regionMap[region]
    return res.status(400).send 'Invalid region and phone number.'

  VerificationCode.getByPhone region, phone
  .then (verification) ->
    if verification
      timeDiff = Math.floor((Date.now() - verification.updatedAt.getTime()) / 1000)

      # 频率限制为 1 分钟 1 条，开发测试环境中 5 秒 1 条
      if req.app.get('env') is 'development'
        subtraction = moment().subtract(5, 's')
      else
        subtraction = moment().subtract(1, 'm')

      if subtraction.isBefore verification.updatedAt
        return res.send new APIResult 5000, null, 'Throttle limit exceeded.'

    code = _.random 1000, 9999

    # 生产环境下才发送短信
    if req.app.get('env') is 'development'
      VerificationCode.upsert
        region: region
        phone: phone
        sessionId: ''
      .then ->
        return res.send new APIResult 200
    else
      # 需要在融云开发者后台申请短信验证码签名，然后选择短信模板 Id
      rongCloud.sms.sendCode region, phone, '9kRzbeLeQx89RMVRd76lpR', (err, resultText) ->
        if err
          logError err.response.text
          return next err.response.text

        result = JSON.parse resultText

        if result.code isnt 200
          return next new Error 'RongCloud Server API Error Code: ' + result.code

        VerificationCode.upsert
          region: region
          phone: phone
          sessionId: result.sessionId
        .then ->
          res.send new APIResult 200
  .catch next

# 验证验证码
router.post '/verify_code', (req, res, next) ->
  phone  = req.body.phone
  region = req.body.region
  code   = req.body.code

  # TODO: 频率限制，防止爆破
  VerificationCode.getByPhone region, phone
  .then (verification) ->
    if not verification
      return res.status(404).send 'Unknown phone number.'
    # 验证码过期时间为 2 分钟
    else if moment().subtract(2, 'm').isAfter verification.updatedAt
      res.send new APIResult 2000, null, 'Verification code expired.'
    # 开发环境下支持万能验证码
    else if req.app.get('env') is 'development' and code is '9999'
      res.send new APIResult 200, verification_token: verification.token
    else
      rongCloud.sms.verifyCode verification.sessionId, code, (err, resultText) ->
        if err
          logError resultText
          return next err

        result = JSON.parse resultText

        if result.code isnt 200
          return next new Error 'RongCloud Server API Error Code: ' + result.code

        if result.success
          res.send new APIResult 200, verification_token: verification.token
        else
          res.send new APIResult 1000, null, 'Invalid verification code.'
  .catch next

# # 检查用户名是否可以注册
# router.post '/check_username_available', (req, res, next) ->
#   username = req.body.username
#
#   checkUsernameAvailable username
#   .then (result) ->
#     if result
#       res.send new APIResult 200, true
#     else
#       res.send new APIResult 200, false, 'Username has already existed.'
#   .catch next

# 检查手机号是否可以注册
router.post '/check_phone_available', (req, res, next) ->
  region = req.body.region
  phone  = req.body.phone

  # 如果不是合法的手机号，直接返回，省去查询数据库的步骤
  if not validator.isMobilePhone phone, regionMap[region]
    return res.status(400).send 'Invalid region and phone number.'

  checkPhoneAvailable region, phone
  .then (result) ->
    if result
      res.send new APIResult 200, true
    else
      res.send new APIResult 200, false, 'Phone number has already existed.'
  .catch next

# 用户注册
router.post '/register', (req, res, next) ->
  nickname          = req.body.nickname
  # username          = req.body.username
  password          = req.body.password
  verification_token  = req.body.verification_token

  if password.indexOf(' ') > 0
    return res.status(400).send 'Password must have no space.'
  if not validator.isLength nickname, NICKNAME_MIN_LENGTH, NICKNAME_MAX_LENGTH
    return res.status(400).send 'Length of nickname invalid.'
  if not validator.isLength password, PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH
    return res.status(400).send 'Length of password invalid.'
  if not validator.isUUID verification_token
    return res.status(400).send 'Invalid verification_token.'

  VerificationCode.getByToken verification_token
  .then (verification) ->
    if not verification
      return res.status(404).send 'Unknown verification_token.'

    # checkUsernameAvailable username
    # .then (result) ->
    #   if result
    checkPhoneAvailable verification.region, verification.phone
    .then (result) ->
      if result
        salt = Utility.random 1000, 9999
        hash = Utility.hash password, salt

        sequelize.transaction (t) ->
          User.create
            nickname: nickname
            # username: username
            region: verification.region
            phone: verification.phone
            passwordHash: hash
            passwordSalt: salt.toString()
          ,
            transaction: t
          .then (user) ->
            DataVersion.create userId: user.id, transaction: t
            .then ->
              Utility.setAuthCookie res, user.id
              Utility.setNicknameCookie res, nickname

              res.send new APIResult 200, Utility.encodeResults id: user.id
      else
        res.status(400).send 'Mobile has already existed.'
      # else
      #   res.status(403).send 'Username has already existed.'
  .catch next

# 用户登录
router.post '/login', (req, res, next) ->
  region   = req.body.region
  phone    = req.body.phone
  password = req.body.password

  # 如果不是合法的手机号，直接返回，省去查询数据库的步骤
  if not validator.isMobilePhone phone, regionMap[region]
    return res.status(400).send 'Invalid region and phone number.'

  User.findOne
    where:
      region: region
      phone: phone
    attributes: [
      'id'
      'passwordHash'
      'passwordSalt'
      'nickname'
      'portraitUri'
      'rongCloudToken'
    ]
  .then (user) ->
    errorMessage = 'Invalid phone or password.'

    if not user
      res.send new APIResult 1000, null, errorMessage
    else
      passwordHash = Utility.hash password, user.passwordSalt

      if passwordHash isnt user.passwordHash
        return res.send new APIResult 1000, null, errorMessage

      Utility.setAuthCookie res, user.id
      Utility.setNicknameCookie res, user.nickname

      GroupMember.findAll
        where:
          memberId: user.id
        attributes: []
        include:
          model: Group
          where:
            deletedAt: null
          attributes: [
            'id'
            'name'
          ]
      .then (groups) ->
        log 'Sync groups: %j', groups

        groupIdNamePairs = {}
        groups.forEach (group) ->
          groupIdNamePairs[Utility.encodeId(group.group.id)] = group.group.name

        log 'Sync groups: %j', groupIdNamePairs

        rongCloud.group.sync Utility.encodeId(user.id), groupIdNamePairs, (err, resultText) ->
          if err
            log "Error: sync user's group list failed: %s", err
      .catch (error) ->
        # Do nothing if error.
        # TODO: log error
        logError 'Sync groups error: ', error

      if user.rongCloudToken is ''
        getToken user.id, user.nickname, user.portraitUri
        .then (token) ->
          res.send new APIResult 200, Utility.encodeResults id: user.id, token: token
        .catch ->
          res.send new APIResult 200, Utility.encodeResults id: user.id, token: ''
      else
        res.send new APIResult 200, Utility.encodeResults id: user.id, token: user.rongCloudToken
  .catch next

# 用户注销
router.post '/logout', (req, res) ->
  res.clearCookie Config.AUTH_COOKIE_NAME
  res.send new APIResult 200

# 通过手机验证码设置新密码
router.post '/reset_password', (req, res, next) ->
  password          = req.body.password
  verification_token  = req.body.verification_token

  if (password.indexOf(' ') != -1)
    return res.status(400).send 'Password must have no space.'
  if not validator.isLength password, PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH
    return res.status(400).send 'Length of password invalid.'
  if not validator.isUUID verification_token
    return res.status(400).send 'Invalid verification_token.'

  VerificationCode.getByToken verification_token
  .then (verification) ->
    if not verification
      return res.status(404).send 'Unknown verification_token.'

    salt = _.random 1000, 9999
    hash = Utility.hash password, salt

    User.update
      passwordHash: hash
      passwordSalt: salt.toString()
    ,
      where:
        region: verification.region
        phone: verification.phone
    .then ->
      res.send new APIResult 200
  .catch next

# 当前用户通过旧密码设置新密码
router.post '/change_password', (req, res, next) ->
  newPassword = req.body.newPassword
  oldPassword = req.body.oldPassword

  if (newPassword.indexOf(' ') != -1)
    return res.status(400).send 'New password must have no space.'
  if not validator.isLength newPassword, PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH
    return res.status(400).send 'Invalid new password length.'

  User.findById req.app.locals.currentUserId,
    attributes: [
      'id'
      'passwordHash'
      'passwordSalt'
    ]
  .then (user) ->
    oldHash = Utility.hash oldPassword, user.passwordSalt

    if oldHash isnt user.passwordHash
      return res.send new APIResult 1000, null, 'Wrong old password.'

    newSalt = _.random 1000, 9999
    newHash = Utility.hash newPassword, newSalt

    user.update
      passwordHash: newHash
      passwordSalt: newSalt.toString()
    .then ->
      res.send new APIResult 200
  .catch next

# 设置自己的昵称
router.post '/set_nickname', (req, res, next) ->
  nickname = req.body.nickname

  if not validator.isLength nickname, NICKNAME_MIN_LENGTH, NICKNAME_MAX_LENGTH
    return res.status(400).send 'Invalid nickname length.'

  currentUserId = req.app.locals.currentUserId
  timestamp = Date.now()

  User.update
    nickname: nickname
    timestamp: timestamp
  ,
    where:
      id: currentUserId
  .then ->
    Utility.setNicknameCookie res, nickname

    Promise.all [
      DataVersion.updateUserVersion currentUserId, timestamp
    ,
      DataVersion.updateAllFriendshipVersion currentUserId, timestamp
    ]
    .then ->
      res.send new APIResult 200
  .catch next

# 设置用户头像地址
router.post '/set_portrait_uri', (req, res, next) ->
  portraitUri = req.body.portraitUri

  if not validator.isURL portraitUri, { protocols: ['http', 'https'], require_protocol: true }
    return res.status(400).send 'Invalid portraitUri format.'
  if not validator.isLength portraitUri, PORTRAIT_URI_MIN_LENGTH, PORTRAIT_URI_MAX_LENGTH
    return res.status(400).send 'Invalid portraitUri length.'

  currentUserId = req.app.locals.currentUserId
  timestamp = Date.now()

  User.update
    portraitUri: portraitUri
    timestamp: timestamp
  ,
    where:
      id: currentUserId
  .then ->
    Promise.all [
      DataVersion.updateUserVersion currentUserId, timestamp
    ,
      DataVersion.updateAllFriendshipVersion currentUserId, timestamp
    ]
    .then ->
      res.send new APIResult 200
  .catch next

# 将好友加入黑名单
router.post '/add_to_blacklist', (req, res, next) ->
  friendId  = req.body.friendId

  currentUserId = req.app.locals.currentUserId
  timestamp = Date.now()

  # 先调用融云服务器接口
  rongCloud.user.blacklist.add Utility.encodeId(currentUserId), Utility.encodeId(friendId), (err, resultText) ->
    # 如果失败直接返回，不保存到数据库
    if err
      next err
    else
      Blacklist.upsert
        userId: currentUserId
        friendId: friendId
        status: true
        timestamp: timestamp
      .then ->
        # 更新版本号（时间戳）
        DataVersion.updateBlacklistVersion currentUserId, timestamp
        .then ->
          res.send new APIResult 200
      .catch next

# 将好友从黑名单中移除
router.post '/remove_from_blacklist', (req, res, next) ->
  friendId  = req.body.friendId

  currentUserId = req.app.locals.currentUserId
  timestamp = Date.now()

  # 先调用融云服务器接口
  rongCloud.user.blacklist.remove Utility.encodeId(currentUserId), Utility.encodeId(friendId), (err, resultText) ->
    # 如果失败直接返回，不保存到数据库
    if err
      next err
    else
      Blacklist.update
        status: false
        timestamp: timestamp
      ,
        where:
          userId: currentUserId
          friendId: friendId
      .then ->
        # 更新版本号（时间戳）
        DataVersion.updateBlacklistVersion currentUserId, timestamp
        .then ->
          res.send new APIResult 200
      .catch next

# 上传用户通讯录
router.post '/upload_contacts', (req, res, next) ->
  contacts = req.body

  # TODO: Not implements.

  res.status(404).send 'Not implements.'

# 获取融云 Token
router.get '/get_token', (req, res, next) ->
  User.findById req.app.locals.currentUserId,
    attributes: [
      'id'
      'nickname'
      'portraitUri'
      'rongCloudToken'
    ]
  .then (user) ->
    getToken user.id, user.nickname, user.portraitUri
    .then (token) ->
      res.send new APIResult 200, Utility.encodeResults { userId: user.id, token: token }, 'userId'
  .catch next

# 获取云存储所用 Token
router.get '/get_image_token', (req, res, next) ->
  qiniu.conf.ACCESS_KEY = Config.QINIU_ACCESS_KEY
  qiniu.conf.SECRET_KEY = Config.QINIU_SECRET_KEY

  putPolicy = new qiniu.rs.PutPolicy 'sealtalk-image'
  token = putPolicy.token()

  res.send new APIResult 200, { target: 'qiniu', token: token }

# 获取短信图形验证码
router.get '/get_sms_img_code', (req, res, next) ->
  rongCloud.sms.getImgCode Config.RONGCLOUD_APP_KEY, (err, resultText) ->
    if err
      return next err

    result = JSON.parse resultText

    if result.code isnt 200
      return next new Error 'RongCloud Server API Error Code: ' + result.code

  res.send new APIResult 200, { url: result.url, verifyId: result.verifyId }

# 获取当前用户黑名单列表
router.get '/blacklist', (req, res, next) ->
  currentUserId = req.app.locals.currentUserId
  timestamp = Date.now()

  Blacklist.findAll
    where:
      userId: currentUserId
      status: true
    attributes: []
    include:
      model: User
      attributes: [
        'id'
        'nickname'
        'portraitUri'
        'updatedAt' # 为节约服务端资源，客户端自己按照 updatedAt 排序
      ]
  .then (dbBlacklist) ->
    # 调用融云服务器接口，获取服务端数据，并和本地做同步
    rongCloud.user.blacklist.query Utility.encodeId(currentUserId), (err, resultText) ->
      if err
        # 如果失败直接忽略
        log 'Error: request server blacklist failed: %s', err
      else
        result = JSON.parse(resultText)

        if result.code is 200
          serverBlacklistUserIds = result.users
          dbBlacklistUserIds = dbBlacklist.map (blacklist) -> blacklist.user.id.toString()

          # 检查和修复数据库中黑名单数据的缺失
          serverBlacklistUserIds.forEach (userId) ->
            if dbBlacklistUserIds.indexOf(userId) is -1
              # 数据库中缺失，添加上这个数据
              Blacklist.create
                userId: currentUserId
                friendId: userId
                status: true
                timestamp: timestamp
              .then ->
                # 不需要处理成功和失败回调
                log 'Sync: fix user blacklist, add %s -> %s from db.', currentUserId, userId

                # 更新版本号（时间戳）
                DataVersion.updateBlacklistVersion currentUserId, timestamp
              .catch ->
                # 可能会有云端的脏数据，导致 userId 不存在，直接忽略了

          # 检查和修复数据库中黑名单脏数据（多余）
          dbBlacklistUserIds.forEach (userId) ->
            if serverBlacklistUserIds.indexOf(userId) is -1
              # 数据库中的脏数据，删除掉
              Blacklist.update
                status: false
                timestamp: timestamp
              ,
                where:
                  userId: currentUserId
                  friendId: userId
              .then ->
                log 'Sync: fix user blacklist, remove %s -> %s from db.', currentUserId, userId

                # 更新版本号（时间戳）
                DataVersion.updateBlacklistVersion currentUserId, timestamp

    res.send new APIResult 200, Utility.encodeResults dbBlacklist, [['user', 'id']]
  .catch next

# 获取当前用户所属群组列表
router.get '/groups', (req, res, next) ->
  GroupMember.findAll
    where:
      memberId: req.app.locals.currentUserId
    attributes: [
      'role'
    ]
    include: [
      model: Group
      attributes: [
        'id'
        'name'
        'portraitUri'
        'creatorId'
        'memberCount'
      ]
    ]
  .then (groups) ->
    res.send new APIResult 200, Utility.encodeResults groups, [['group', 'id'], ['group', 'creatorId']]
  .catch next

# 同步用户的好友、黑名单、群组、群组成员数据
# 客户端的调用时机：客户端打开时
router.get '/sync/:version', (req, res, next) ->
  version = req.params.version

  if not validator.isInt version
    return res.status(400).send 'Version parameter is not integer.'

  maxVersions = []

  currentUserId = req.app.locals.currentUserId

  DataVersion.findById currentUserId
  .then (dataVersion) ->
    co ->
      # 获取变化的用户（自己）信息
      if dataVersion.userVersion > version
        user = yield User.findById currentUserId,
          attributes: [
            'id'
            'nickname'
            'portraitUri'
            'timestamp'
          ]

      # 获取变化的黑名单信息
      if dataVersion.blacklistVersion > version
        blacklist = yield Blacklist.findAll
          where:
            userId: currentUserId
            timestamp:
              $gt: version
          attributes: [
            'friendId'
            'status'
            'timestamp'
          ]

      # 获取变化的好友信息
      if dataVersion.friendshipVersion > version
        friends = yield Friendship.findAll
          where:
            userId: currentUserId
            timestamp:
              $gt: version
          attributes: [
            'friendId'
            'displayName'
            'status'
            'timestamp'
          ]

      # 获取变化的当前用户加入的群组信息
      if dataVersion.groupVersion > version
        groups = yield GroupMember.findAll
          where:
            memberId: currentUserId
            timestamp:
              $gt: version
          attributes: [
            'displayName'
            'role'
            'isDeleted'
          ]
          include: [
            model: Group
            attributes: [
              'id'
              'name'
              'portraitUri'
              'timestamp'
            ]
          ]

      # 获取变化的当前用户加入的群组成员信息
      if dataVersion.groupVersion > version
        groupMembers = yield GroupMember.findAll
          where:
            memberId: currentUserId
            timestamp:
              $gt: version
          attributes: [
            'groupId'
            'memberId'
            'displayName'
            'role'
            'isDeleted'
            'timestamp'
          ]
          include: [
            model: User
            attributes: [
              'nickname'
              'portraitUri'
            ]
          ]

      maxVersions.push(user.timestamp) if user
      maxVersions.push(_.max(blacklist, (item) -> item.timestamp).timestamp) if blacklist
      maxVersions.push(_.max(friends, (item) -> item.timestamp).timestamp) if friends
      maxVersions.push(_.max(groups, (item) -> item.group.timestamp).group.timestamp) if groups
      maxVersions.push(_.max(groupMembers, (item) -> item.timestamp).timestamp) if groupMembers

      log 'maxVersions: %j', maxVersions

      res.send new APIResult 200,
        version: _.max(maxVersions) # 最大的版本号
        user: user
        blacklist: blacklist
        friends: friends
        groups: groups
        group_members: groupMembers
  .catch next

# 获取用户信息
router.get '/:id', (req, res, next) ->
  userId = req.params.id

  userId = Utility.decodeIds userId

  User.findById userId,
    attributes: [
      'id'
      'nickname'
      'portraitUri'
    ]
  .then (user) ->
    if not user
      return res.status(404).send 'Unknown user.'

    res.send new APIResult 200, Utility.encodeResults user
  .catch next

# 根据手机号查找用户信息
router.get '/find/:region/:phone', (req, res, next) ->
  region = req.params.region
  phone = req.params.phone

  # 如果不是合法的手机号，直接返回，省去查询数据库的步骤
  if not validator.isMobilePhone phone, regionMap[region]
    return res.status(400).send 'Invalid region and phone number.'

  User.findOne
    where:
      region: region
      phone: phone
    attributes: [
      'id'
      'nickname'
      'portraitUri'
    ]
  .then (user) ->
    if not user
      return res.status(404).send 'Unknown user.'

    res.send new APIResult 200, Utility.encodeResults user
  .catch next

module.exports = router
