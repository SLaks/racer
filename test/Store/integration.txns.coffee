{expect, calls} = require '../util'
{finishAfter} = require '../../lib/util/async'
transaction = require '../../lib/transaction'
{mockFullSetup} = require '../util/model'
racer = require '../../lib/racer'

racer.use require('../db-async-memory')
racer.use racer.logPlugin
describe 'Failed Store txns', ->
  it 'should not affect later txns', (done) ->
    store = racer.createStore { db: { type: 'AsyncMemory', errorPaths: /error/ } }
    @timeout 300
    mockFullSetup store, done, [],
      preBundle: (model) ->
      postBundle: (model) ->
      preConnect: (model) ->
      postConnect: (model, done) ->
        model.set 'error.1', true, (err) ->
          expect(err).to.equal 'Boom!'
          model.set 'good.1', true, ->
            expect(model.get('good.1')).to.equal true
            done()
  it 'should not affect later txns when missing persistence handlers', (done) ->
    store = racer.createStore { db: { type: 'AsyncMemory', errorPaths: /error/ } }
    @timeout 300
    mockFullSetup store, done, [],
      preBundle: (model) ->
      postBundle: (model) ->
      preConnect: (model) ->
      postConnect: (model, done) ->
        model.set 'error.1', +new Date(), (err) ->
          expect(err).to.equal 'Boom!'
          model.set 'error.2', +new Date(), (err) ->
            expect(err).to.equal 'Boom!'
            model.set 'callNext.bad', +new Date(), (err) ->
              expect(err).to.match /^No persistence handler for set\(callNext.bad/
              model.push 'callNext.bad', +new Date(), (err) ->
                expect(err).to.match /^No persistence handler for push\(callNext.bad/
                model.set 'good.1', true, ->
                  expect(model.get('good.1')).to.equal true
                  done()
  it 'should not affect simultaneous txns', (done) ->
    @timeout 300
    store = racer.createStore { db: { type: 'AsyncMemory', errorPaths: /error/ } }
    mockFullSetup store, done, [],
      postConnect: (model, done) ->
        done = finishAfter 4, done

        directModel = store.createModel()
        directModel.set 'good.1', 82, ->
          expect(directModel.get('good.1')).to.equal 82
          done()
        directModel.set 'callNext.bad', true, (err) ->
          expect(err.message).to.match /^No persistence handler for set\(callNext.bad/
          done()

        model.set 'good.1', true, ->
          expect(model.get('good.1')).to.equal true
          done()
        model.set 'error.1', true, (err) ->
          expect(err).to.equal 'Boom!'
          done()

describe 'Failed direct store txns', ->
  it 'should not affect simultaneous txns', calls 4, (done) ->
    @timeout 300
    store = racer.createStore { db: { type: 'AsyncMemory', errorPaths: /error/ } }
    model = store.createModel()
    model.set 'good.1', true, ->
      expect(model.get('good.1')).to.equal true
      done()
    model.set 'callNext.bad', true, (err) ->
      expect(err.message).to.match /^No persistence handler for set\(callNext.bad/
      done()
    model.set 'good.1', true, ->
      expect(model.get('good.1')).to.equal true
      done()
    model.set 'error.1', true, (err) ->
      expect(err.message).to.equal 'Boom!'
      done()

# TODO More tests
module.exports = (plugins) ->
  describe 'Store transactions', ->
    it 'events should be emitted in remote subscribed models', (done) ->
      mockFullSetup @store, done, plugins, (modelA, modelB, done) ->
        modelA.on 'set', '_test.color', (value, previous, isLocal) ->
          expect(value).to.equal 'green'
          expect(previous).to.equal undefined
          expect(isLocal).to.equal false
          expect(modelA.get '_test.color').to.equal 'green'
          done()
        modelB.set '_test.color', 'green'

  describe 'a quickly reconnected client', ->
    it 'should receive transactions buffered by the store while it was offline', (done) ->
      store = @store
      oldVer = null
      mockFullSetup store, done, plugins,
        preBundle: (model) ->
          model.set '_test.color', 'blue'
        postBundle: (model) ->
          path = model.dereference('_test') + '.color'
          txn = transaction.create
            id: '1.0', method: 'set', args: [path, 'green'], ver: ++model._memory.version
          store.publish path, 'txn', txn
        preConnect: (model) ->
          expect(model.get('_test.color')).to.equal 'blue'
          oldVer = model._memory.version
        postConnect: (model, done) ->
          process.nextTick -> process.nextTick ->
            expect(model.get('_test.color')).to.equal 'green'
            expect(model._memory.version).to.equal oldVer+1
            done()
