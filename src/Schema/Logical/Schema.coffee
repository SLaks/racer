Promise = require '../../Promise'
FlowBuilder = require '../FlowBuilder'
CommandSequence = require '../CommandSequence'
{EventedKlass} = require '../Klass'

# This is how we define our logical schema (vs our data source schema).
# At this layer of abstraction:
# - We take care of validation, most typecasting, and methods encapsulating business logic.
# - There is no distinction between virtual and non-virtual attributes.

LogicalSchema = module.exports = EventedKlass.extend 'LogicalSchema',
  # @constructor
  # @param {String -> Object} attrs maps path names to their values
  # @param {Boolean} isNew; will be false when populating this from the
  #                  results of a Query
  # @param {Array} oplog, log of operations. Instead of a dirty tracking
  #     object, we keep an oplog, which we can leverage better at the Adapter
  #     layer - e.g., collapse > 1 same-path pushes into 1 push for Mongo
  # @param {??} assignerDoc ??
  init: (attrs, @isNew = true, oplog, assignerDoc = @) ->
    @oplog = oplog || LogicalSchema.oplog || []
    @oplog.reset ||= -> @length = 0
    @oplog.nextCid ||= 1
    @cid = @oplog.nextCid++ if @isNew
    @_json = {}

    SubClass = @constructor
    @_super.apply @, arguments

    if attrs then for attrName, attrVal of attrs
      # TODO attrs may contain nested objects
      # TODO Lazy casting later?
      field = SubClass.fields[attrName]

      # 1st conditional term (field): Cast defined fields; ad hoc fields skip this
      # 2nd conditional term (attrVal): Don't cast undefineds
      if field && (attrVal isnt undefined)
        oplog = if @isNew then @oplog else null
        attrVal = field.cast attrVal, oplog, assignerDoc
      if @isNew
        @set attrName, attrVal
      else
        @_assignAttrs attrName, attrVal

  toJSON: -> @_json

  _assignAttrs: (name, val, obj = @_json) ->
    {fields, _name: schemaName} = LogicalSkema = @constructor
    if field = fields[name]
      oplog = if @isNew then @oplog else null
      return obj[name] = field.cast val, oplog, @

    if val.constructor == Object
      for k, v of val
        nextObj = obj[name] ||= {}
        @_assignAttrs k, v, nextObj
      return obj[name]

    throw new Error "Either `#{name}` isn't a field of `#{schemaName}`, or `#{val}` is not an Object"

  atomic: ->
    return Object.create @,
      _atomic: value: true

  set: (attr, val, callback) ->
    # Remember oplogIndex because @_assignAttrs modifies @oplog
    oplogIndex = @oplog.length
    val = @_assignAttrs attr, val
    if pkeyVal = @getPkey()
      conds = {}
      conds[@pkey] = pkeyVal
    else
      conds = __cid__: @cid
    if val instanceof LogicalSchema
      if fkey = val.getPkey()
        setTo = {}
        setTo[@pkey] = fkey
      else
        setTo = cid: val.cid
      op = [@, @constructor.ns, conds, 'set', attr, setTo]
      @oplog.splice oplogIndex, 0, op
#      @oplog.push [@, @constructor.ns, conds, 'set', attr, setTo]
      # Leaving off a val means assign this attr to the
      # document represented in the next op
    else
      @oplog.push [@, @constructor.ns, conds, 'set', attr, val]
    # Otherwise this operation is stored in val's oplog, since val is a LogicalSchema document
    if @_atomic then @save callback
    return @

  # Get from in-memory local @_json
  get: (attr) -> return @_json[attr]

  pkey: '_id'
  getPkey: -> @_json[@pkey]

  del: (attr, callback) ->
    if pkeyVal = @getPkey()
      conds = {}
      conds[@pkey] = pkeyVal
    @oplog.push [@, @constructor.ns, conds, 'del', attr]
    if @_atomic then @save callback
    return @

  # self-destruct
  destroy: (callback) ->
    if pkeyVal = @getPkey()
      conds = {}
      conds[@pkey] = pkeyVal
    @oplog.push [@, @constructor.ns, conds, 'destroy']
    LogicalSchema.applyOps oplog, callback

  push: (attr, vals..., callback) ->
    if typeof callback isnt 'function'
      vals.push callback
      callback = null

    {fields, ns} = CustomLogicalSchema = @constructor
    # TODO DRY - This same code apperas in _assignAttrs
    # TODO In fact, this may already be part of Field::cast
    field = fields[attr]
    vals = field.cast vals, if @isNew then @oplog else null
    arr = @_json[attr] ||= []
    arr.push vals...

    if pkeyVal = @getPkey()
      conds = {}
      conds[@pkey] = pkeyVal
    else
      conds = __cid__: @cid

    if field.type.memberType.prototype instanceof LogicalSchema
      setTo = []
      for mem, i in vals
        setTo[i] = cid: mem.cid
      @oplog.splice @oplog.length-vals.length, 0, [@, @constructor.ns, conds, 'push', attr, setTo...]
    else
      @oplog.push [@, ns, conds, 'push', attr, vals...]
    if @_atomic
      @save callback
    return @

  # @param {Function} callback(err, document)
  save: (callback) ->
    oplog = @oplog.slice()
    @oplog.reset()
    LogicalSchema.applyOps oplog, (err) =>
      return callback err if err
      @isNew = false
      callback null, @

  validate: ->
    errors = []
    for fieldName, field of @constructor.fields
      result = field.validate @_json[fieldName]
      continue if result is true
      errors = errors.concat result
    return if errors.length then errors else true

, # STATIC METHODS
  createField: -> new Field @

  field: (fieldName, setToField) ->
    return field if field = @fields[fieldName]
    return @fields[fieldName] = setToField

  cast: (val, oplog, assignerDoc) ->
    if val.constructor == Object
      # TODO Should the 2nd args here always be true?
      return new @ val, true, oplog, assignerDoc if oplog
      return new @ val, true, undefined, assignerDoc
    return val if val instanceof @
    # When the val is a primary key value, then
    # do a circular reference
    if assignerDoc && (val == assignerDoc.getPkey())
      return assignerDoc
    throw new Error val + ' is neither an Object nor a ' + @_name

  # TODO Do we even need dataSchemas as a static here?
  dataSchemas: []
  # We use this to define a "data source schema" and link it to
  # this "logical Schema".
  createDataSchema: (source, ns, fieldsConf, virtualsConf) ->
    # createDataSchema(source, fieldsConf)
    if arguments.length == 2
      virtualsConf = null
      fieldsConf = ns
      ns = @ns # Inherit data schema ns from logical schema

    if arguments.length == 3
      switch typeof ns
        when 'boolean', 'string'
          # createDataSchema(source, ns, fieldsConf)
          virtualsConf = null
        else
          # createDataSchema(source, fieldsConf, virtualsConf)
          virtualsConf = fieldsConf
          fieldsConf = ns
          ns = @ns # Inherit data schema ns from logical schema

    # else
    # createDataSchema(source, ns, fieldsConf, virtualsConf)

    LogicalSchema._sources[source._name] ||= source
    dataSchema = source.createDataSchema {LogicalSkema: @, ns}, fieldsConf, virtualsConf
    @dataSchemas.push dataSchema

#      # In case data schema already exists
#      # TODO Implement addDataFields and addVirtualFields
#      for field, descriptor of fieldsConf
#        source.addDataField @, ns, field, fieldsConf
#      for virtual, descriptor of virtualsConf
#        source.addVirtualField @, ns, virtual, descriptor

    return dataSchema

  # Interim method used to help transition from non-Schema to
  # Schema-based approach.
  toOplog: (pkeyVal, method, args) ->
    conds = {}
    conds[@pkey] = pkeyVal
    [ [@constructor.ns, conds, method, args] ]

  create: (attrs, callback, oplog = LogicalSchema.oplog) ->
    doc = new @(attrs, true, oplog)
    doc.save callback

  update: (conds, attrs, callback) ->
    oplog = ([@ns, conds, 'set', path, val] for path, val of attrs)
    LogicalSchema.applyOps oplog, callback

  destroy: (conds, callback) ->
    oplog = [ [@ns, conds] ]
    LogicalSchema.applyOps oplog, callback

  plugin: (plugin, opts) ->
    plugin @, opts
    return @

  # Defines which data source to try first, second, etc.
  # for fetching the values of specific fields. If there 
  # isn't a flow defined for a given field, the querying
  # implementation will use a read flow defined for the
  # LogicalSchema to which the field belongs.
  #
  # Invoking this fn signature will result in defining
  # a fallback read flow for the entire LogicalSchema
  #   defineReadFlow(function (flow) {
  #     flow.
  #       first(mongo, callbackA).
  #       then(mysql, callbackB);
  #   });
  #
  # Otherwise, invoking this fn signature will result 
  # in defining a read flow for the given fields
  #   defineReadFlow(fieldA, fieldB, function (flow) {
  #     flow.
  #       first(mongo, redis, callbackA).
  #       then(mysql, callbackB);
  #   });
  defineReadFlow: (args...) ->
    callback    = args.pop()
    fieldNames  = args
    flowBuilder = new FlowBuilder

    callback flowBuilder
    if fieldNames.length
      fields = @fields
      for name in fieldNames
        fields[name].dataFields.readFlow = flowBuilder.flow
    else
      @readFlow = flowBuilder.flow
    return @

  defFlow: (fieldName, callbacksByIntent) ->
    field = @fields[fieldName]
    field.flow = {}
    for intent, callback of callbacksByIntent
      flow = new Flow
      callback flow
      field.flow[intent] = flow

  lookupField: (path) ->
    return [field, ''] if field = @fields[path]
    parts = path.split '.'
    for part in parts
      if subpath
        subpath += '.' + part
      else
        subpath = part
      if Skema = @fields[subpath]
        [field, ownerPathRelToRoot] = Skema.lookupField path.substring(subpath.length + 1)
        return [field, subpath + '.' + ownerPathRelToSkema]
    throw new Error "path '#{path}' does not appear to be reachable from Schema #{@_name}"

AbstractSchema = require '../AbstractSchema'
for _k, _v of AbstractSchema
  LogicalSchema.static _k, _v

LogicalSchema._schemas = {} # Maps schema namespaces -> LogicalSchema subclasses
LogicalSchema._sources = {} # Maps source names -> DataSource instances
bootstrapField = (field, fieldName, SubSkema) ->
  field.sources = [] # TODO Are we using field.sources?
  field.path    = fieldName
  field.schema  = SubSkema
  SubSkema.field fieldName, field
LogicalSchema.extend = (name, ns, fields) ->
  SubSkema = EventedKlass.extend.call @, name, fields, {ns, fields: {}}
  for fieldName, descriptor of fields
    field = LogicalSchema._createFieldFrom descriptor, fieldName
    if field instanceof Promise
      field.callback (schema) ->
        field = schema.createField()
        bootstrapField field, fieldName, SubSkema
    else
      bootstrapField field, fieldName, SubSkema

  LogicalSchema._schemaPromises[name]?.fulfill SubSkema
  return LogicalSchema._schemas[ns] = SubSkema

# Takes a path such as 'users.5.name', and returns
# {Skema: User, id: '5', path: 'name'}
LogicalSchema.fromPath = (path) ->
  pivot = path.indexOf '.'
  ns    = path.substring 0, pivot
  path  = path.substring pivot+1
  pivot = path.indexOf '.'
  id    = path.substring 0, pivot
  path  = path.substring pivot+1
  return { Skema: @_schemas[ns], id, path }

# Send the oplog to the data sources, where they
# convert the ops into db commands and exec them
#
# @param {Array} oplog
# @param {Function} callback(err, doc)
LogicalSchema.applyOps = (oplog, callback) ->
  cmdSeq = CommandSequence.fromOplog oplog, @_schemas
  return cmdSeq.fire (err, cid, extraAttrs) ->
    return callback(err || null)

# Copy over `where`, `find`, `findOne`, etc from Query::,
# so we can do e.g., LogicalSchema.find, LogicalSchema.findOne, etc
LogicalQuery = require './Query'
for queryMethodName, queryFn of LogicalQuery::
  continue unless typeof queryFn is 'function'
  do (queryFn) ->
    LogicalSchema.static queryMethodName, (args...)->
      query = new LogicalQuery @
      return queryFn.apply query, args

contextMixin = require './mixin.context'
LogicalSchema.mixin contextMixin

actLikeTypeMixin =
  static:
    setups: []
    validators: []

Type = require './Type'
for methodName, method of Type::
  continue if methodName == 'extend'
  actLikeTypeMixin.static[methodName] = method

LogicalSchema.mixin actLikeTypeMixin

# Email = LogicalSchema.type 'Email',
#   extend: String
#
# Email.validate (val, callback) ->
#   # ...
#
# LogicalSchema.type 'Number',
#   get: (val, doc) -> parseInt val, 10
#   set: (val, doc) -> parseInt val, 10
LogicalSchema.type = (typeName, config) ->
  return type if type = @_types[typeName]

  if parentType = config.extend
    config.extend = @type parentType unless parentType instanceof Type
  type = @_types[typeName] = new Type typeName, config

  return type
LogicalSchema._types = {}

LogicalSchema._createFieldFrom = (descriptor, fieldName) ->
  if descriptor.constructor != Object
    type = @inferType descriptor
    return type if type instanceof Promise
    return type.createField()

  if type = descriptor.$type
    # e.g.,
    # username:
    #   $type: String
    #   validator: fn
    type = @inferType type
    # Will be a Promise when the descriptor involves a
    # yet-to-be-defined LogicalSchema
    return type if type instanceof Promise
    field = type.createField()
    delete descriptor.$type
    for method, arg of descriptor
      if Array.isArray arg
        field[method] arg...
      else
        field[method] arg
    return field
  throw new Error "Could not create a field from: #{descriptor}"

# Factory method returning new Field instances
# generated from factory create new Type instances
LogicalSchema.inferType = (descriptor) ->
  if Array.isArray descriptor
    arrayType         = @type 'Array'
    concreteArrayType = Object.create arrayType
    memberDescriptor  = descriptor[0]
    memberType        = @inferType memberDescriptor
    if memberType instanceof Promise
      memberType.callback (schema) ->
        concreteArrayType.memberType = schema
    else
      concreteArrayType.memberType = memberType
    return concreteArrayType
  switch descriptor
    when Number  then return @type 'Number'
    when Boolean then return @type 'Boolean'
    when String  then return @type 'String'

  # Allows developers to refer to a LogicalSchema before it's defined
  if typeof descriptor is 'string'
    return @_schemaPromise descriptor

  return descriptor if descriptor           instanceof Type ||
                       descriptor.prototype instanceof LogicalSchema

  throw new Error 'Unsupported descriptor ' + descriptor

# We use this when we want to reference a LogicalSchema
# that we have not yet defined but that we need for another
# LogicalSchema that we are defining at the moment.
# e.g.,
# LogicalSchema.extend 'User', 'users',
#   tweets: ['Tweet']
#
# LogicalSchema.inferType delegates to the following LogicalSchema promise code
LogicalSchema._schemaPromise = (schemaName) ->
  # Cache only one promise per schema
  schemaPromises = @_schemaPromises
  return promise if promise = schemaPromises[schemaName]
  promise = schemaPromises[schemaName] = new Promise
  schemasToDate = LogicalSchema._schemas
  for ns, schema of schemasToDate
    if schema._name == schemaName
      promise.fulfill schema
      return promise
  return promise
LogicalSchema._schemaPromises = {}

LogicalSchema.type 'String',
  cast: (val) -> val.toString()

LogicalSchema.type 'Number',
  cast: (val) -> parseFloat val, 10

LogicalSchema.type 'Array',
  cast: (list, oplog, assignerDoc) ->
    return (@memberType.cast member, oplog, assignerDoc for member in list)

Field = require './Field'
