module.exports = RefHelper = (model) ->
  @_model = model
  @_adapter = model._adapter
  return

RefHelper:: =
  # If a key is present, merges
  #     { "#{path}": { "#{ref}": { "#{key}": 1 } } }
  # into
  #     "$keys":
  #       "#{key}":
  #         $:
  #
  # and merges
  #     { "#{path}": { "#{ref}": { "#{key}": 1 } } }
  # into
  #     "$refs":
  #       "#{ref}.#{keyObj}": 
  #         $:
  #
  # If key is not present, merges
  #     "#{path}": { "#{ref}": { $: 1 } }
  # into
  #     "$refs":
  #       "#{ref}": 
  #         $:
  #
  # $refs is a kind of index that allows us to lookup
  # which references pointed to the path, `ref`, or to
  # a path that `ref` is a descendant of.
  #
  # @param {String} path that is de-referenced to a true path represented by
  #                 lookup(ref + '.' + lookup(key))
  # @param {String} ref is what would be the `value` of $r: `value`.
  #                 It's what we are pointing to
  # @param {String} key is a path that points to a pathB or array of paths
  #                 as another lookup chain on the dereferenced `ref`
  # @param {Object} options
  setRefs: (path, ref, key, options) ->
    adapter = @_adapter
    if key
      refMap = adapter._lookup("$keys.#{key}.$", true, options).obj[path] ||= {}
      keyMap = refMap[ref] ||= {}
      keyMap[key] = 1
      keyObj = adapter._lookup(key, false, options).obj
      # keyObj is only valid if it can be a valid path segment
      return if keyObj is undefined
      refsKey = ref + '.' + keyObj
    else
      refsKey = ref
    
    refMap = adapter._lookup("$refs.#{refsKey}.$", true, options).obj[path] ||= {}
    keyMap = refMap[ref] ||= {}
    if key
      keyMap[key] = 1
    else
      keyMap['$'] = 1

  updateRefsForKey: (path, options) ->
    self = this
    if refs = @_adapter._lookup("$keys.#{path}.$", false, options).obj
      @_eachValidRef refs, options.obj, (path, ref, key) ->
        self.setRefs path, ref, key, options

  _fastLookup: (path, obj) ->
    for prop in path.split '.'
      return unless obj = obj[prop]
    return obj
  _eachValidRef: (refs, obj = @_adapter._data, callback) ->
    fastLookup = @_fastLookup
    for path, refMap of refs
      for ref, keyMap of refMap
        for key of keyMap
          key = undefined if key == '$'
          # Check to see if the reference is still the same
          o = fastLookup path, obj
          if o && o.$r == ref && o.$k == key
            callback path, ref, key
          else
            delete keyMap[key]
        if Object.keys(keyMap).length == 0
          delete refMap[ref]
      if Object.keys(refMap).length == 0
        delete refMap[path]

  notifyPointersTo: (path, method, args, emitPathEvents) ->
    model = @_model
    self = this
    if refs = model.get '$refs'
      _data = model.get()
      # Passes back a set of references when we find references to path.
      # Also passes back a set of references and a path remainder
      # every time we find references to any of path's ancestor paths
      # such that `ancestor_path + path_remainder == path`
      eachRefSetPointingTo = (path, fn) ->
        i = 0
        refPos = refs
        props = path.split '.'
        while prop = props[i++]
          return unless refPos = refPos[prop]
          fn refSet, props.slice(i).join('.') if refSet = refPos.$
      emitRefs = (targetPath) ->
        eachRefSetPointingTo targetPath, (refSet, targetPathRemainder) ->
          # refSet has signature: { "#{pointingPath}$#{ref}": [pointingPath, ref], ... }
          self._eachValidRef refSet, _data, (pointingPath) ->
            pointingPath += '.' + targetPathRemainder if targetPathRemainder
            emitPathEvents pointingPath
            emitRefs pointingPath
      emitRefs path
