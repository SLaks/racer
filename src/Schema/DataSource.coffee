{merge} = require '../util'
DataSchema = require './DataSchema'

# Custom DataSource classes are defined via:
# DataSource.extend({
#   set: function (...) {...},
#   del: function (...) {...}
# })
DataSource = module.exports = (@adapter) ->
  @dataSchemasWithNs = {} # Maps namespace -> Data Schema
  @adapter ||= new AdapterClass() if AdapterClass = @AdapterClass
  return

DataSource:: =
  connect: (config, callback) -> @adapter.connect config, callback
  disconnect: (callback) -> @adapter.disconnect callback
  flush: (callback) -> @adapter.flush callback

  # Shortcut method for use in data source schemas
  # to generate a descriptor specifying a field's
  # type and the fact that it is as a primary key.
  # e.g.,
  #     CustomSchema.source(mongo, ns, {
  #       _id: mongo.pkey(ObjectId)
  #     });
  pkey: (fieldNameOrType) ->
    if 'string' == typeof fieldNameOrType
      return @_pkeyField = fieldNameOrType
    return {
      $type: fieldNameOrType
      $pkey: true
    }

  # @param {Function} the custom LogicalSchema subclass
  # @param {String|False} ns is the namespace relative to the data source (as
  #     opposed to the logical source schema). `false` means that this is to 
  #     be used for embedded docs
  # @param {Object} conf maps field names to type descriptor; a type
  #     descriptor can be any number of syntactic representations of the 
  #     type the field is.
  createDataSchema: ({name, ns, LogicalSchema: LogicalSkema}, fieldsConf) ->
    if LogicalSkema
      ns ||= LogicalSkema.ns
      name ||= LogicalSkema._name
    else
      throw new Error 'Missing name' unless name
      throw new Error 'Missing ns' unless ns == false || 'string' == typeof ns
    ds = @[name] = new DataSchema @, name, ns, LogicalSkema, fieldsConf
    if ns
      @dataSchemasWithNs[ns] = ds
    return ds

DataSource.extend = (config) ->
  ParentSource = @
  ChildSource = ->
    ParentSource.apply @, arguments
    return

  ChildSource:: = new ParentSource
  ChildSource::constructor = ChildSource

  merge ChildSource::, config

  ChildSource.extend = DataSource.extend

  return ChildSource