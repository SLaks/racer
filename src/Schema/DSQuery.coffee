Promise = require '../Promise'

# TODO Rename this - it's confusable with DataQuery
DSQuery = module.exports = (@conds, @_queryMethod) ->
  @_includeFields = {}
  @_logicalFields = {}
  @_fieldPromises = {}
  return

# TODO
DSQuery.condsRelTo = (dataField, LogicalSkema, conds) ->

DSQuery:: =
  # @param {LogicalField} logicalField
  # @param {Boolean} didNotFind indicates whether the success/failure of the previous DSQuery
  notifyAboutPrevQuery: (logicalField, didNotFind) ->
    logicalFields = @_logicalFields
    logicalPath = logicalField.path
    dataFields = logicalFields[logicalPath]
    _includeFields = @_includeFields
    for dataField in dataFields
      if didNotFind then delete _includeFields[dataField.path]
    delete logicalFields[logicalPath]
    @fire() unless Object.keys(logicalFields).length

  # @param {DataField} dataField
  # @param {Promise} dataFieldProm
  add: (dataField, dataFieldProm) ->
    @source ||= dataField.source
    fieldPath = dataField.path
    @_includeFields[fieldPath] = dataField
    @_fieldPromises[fieldPath] = dataFieldProm
    dataFields = @_logicalFields[dataField.logicalField.path] ||= []
    dataFields.push dataField

  fire: ->
    fields = @_includeFields
    anyFields = false
    for k of fields
      anyFields = true
      {ns} = fields[k]
      break
    fieldPromises = @_fieldPromises
    if anyFields
      queryMethod = @_queryMethod
      DataSkema = @source.dataSchemasWithNs[ns]
      return DataSkema[queryMethod] @conds, {fields}, (err, json) ->
        if queryMethod == 'find'
          for path, field of fields
            if field.type.isPkey
              pkeyPath = path
              break
          resolveToByPath = {}
          for mem, i in json
            pkeyVal = mem[pkeyPath]
            for path, val of mem
              resolveToByPath[path] ||= []
              resolveToByPath[path][i] = {val, pkeyVal}
          for path, promise of fieldPromises
            promise.resolve err, resolveToByPath[path], fields[path]
        else
          for path, promise of fieldPromises
            promise.resolve err, json[path], fields[path]

    # TODO Consider the following code. Remove or complete?
    throw new Error 'Unimplemented'
    prom = new Promise
    prom.fulfill null
    return prom