assert = require 'assert'
http = require 'http'
util = require 'util'

# For testing the streaming library
#clientio = require('../../lib/Socket.io-node-client/io-client').io
clientio = require('Socket.io-node-client').io

server = require '../src/server'
events = server.events
db = server.db

types = require '../src/types'
randomizer = require './randomizer'
require './types'

client = require '../src/client'
DeltaStream = require('../src/client/stream').DeltaStream

p = util.debug
i = util.inspect

hostname = 'localhost'
port = 8768
httpclient = null

testCase = require('nodeunit').testCase


# Setup the local db server before the tests run.
# At some stage, it might be worth moving this into a setUp() function of a test runner.
server.server.listen 8768, () ->
	httpclient = http.createClient port, hostname

server.socket.install(server.server)


# Expected data is an array of objects.
expectData = (socket, expectedData, callback) ->
	listener = (data) ->
		#		p "expectData recieved #{i data}"
		expected = expectedData.shift()
		assert.deepEqual expected, data

		if expectedData.length == 0
			socket.removeListener 'message', listener
			callback()
	
	socket.on 'message', listener

#     Utility methods

# Async fetch. Aggregates whole response and sends to callback.
# Callback should be function(response, data) {...}
fetch = (method, path, postData, callback) ->
	assert.ok httpclient

	request = httpclient.request(method, path, {host: hostname})

	if postData?
		postData = JSON.stringify(postData) if typeof(postData) == 'object'
		request.write(postData)

	request.end()

	request.on('response', (response) ->
		data = ''
		response.on('data', (chunk) -> data += chunk)
		response.on('end', () -> callback(response, data))
	)


# Callback will be called after all the ops have been applied, with the
# resultant snapshot. Callback format is callback(error, snapshot)
applyOps = (docName, startVersion, ops, callback) ->
	op = ops.shift()
	db.applyDelta docName, {version:startVersion, op:op}, (error, appliedVersion) ->
		if error
			callback(error, null)
		else
			if ops.length == 0
				db.getSnapshot docName, (snapshot) ->
					callback(null, snapshot)
			else
				applyOps docName, startVersion + 1, ops, callback

# Generate a new, locally unique document name.
newDocName = do ->
	index = 1
	() -> 'doc' + index++


#      TESTS

# Testing tool tests
exports.tools = {
	'create new doc name with each invocation of newDocName()': (test) ->
		test.notStrictEqual newDocName(), newDocName()
		test.strictEqual typeof newDocName(), 'string'
		test.done()
}

# DB tests
exports.db = {
	'Return null when asked for the snapshot of a new object': (test) ->
		db.getSnapshot newDocName(), (data) ->
			test.deepEqual data, {v:0, type:null, snapshot:null}
			test.done()

	'Apply a set type op correctly sets the type and version': (test) ->
		db.applyDelta newDocName(), {version:0, op:{type:'simple'}}, (error, appliedVersion) ->
			test.ifError(error)
			test.strictEqual appliedVersion, 0
			test.done()
	
	'Return a fresh snapshot after submitting ops': (test) ->
		name = newDocName()
		db.applyDelta name, {version:0, op:{type:'simple'}}, (error, appliedVersion) ->
			test.ifError(error)
			test.strictEqual appliedVersion, 0
			db.getSnapshot name, (data) ->
				test.deepEqual data, {v:1, type:types.simple, snapshot:{str:''}}

				db.applyDelta name, {version:1, op:{position: 0, text:'hi'}}, (error, appliedVersion) ->
					test.ifError(error)
					test.strictEqual appliedVersion, 1
					db.getSnapshot name, (data) ->
						test.deepEqual data, {v:2, type:types.simple, snapshot:{str:'hi'}}
						test.done()

	'Apply op to future version fails': (test) ->
		db.applyDelta newDocName(), {version:1, type:{v:1,op:{}}}, (err, result) ->
			test.ok err
			test.done()
	
	'Apply ops at the most recent version': (test) ->
		applyOps newDocName(), 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi '}
				{position: 3, text: 'mum'}
				{position: 3, text: 'to you '}
			], (error, data) ->
				test.strictEqual error, null
				test.strictEqual data.v, 4
				test.deepEqual data.snapshot.str, 'Hi to you mum'
				test.done()
				
	'Apply ops at an old version': (test) ->
		name = newDocName()
		applyOps name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi '}
				{position: 3, text: 'mum'}
			], (error, data) ->
				test.strictEqual error, null
				test.strictEqual data.v, 3
				test.deepEqual data.snapshot.str, 'Hi mum'

				applyOps name, 2, [
					{position: 2, text: ' to you'}
				], (error, data) ->
					test.strictEqual error, null
					test.strictEqual data.v, 4
					test.deepEqual data.snapshot.str, 'Hi to you mum'
					test.done()
	

	'delete a document when delete is called': (test) ->
		name = newDocName()
		db.applyDelta name, {version:0, op:{type:'simple'}}, (error, appliedVersion) ->
			test.ifError(error)
			db.delete name, (error) ->
				test.ifError(error)
				test.done()
	
	'Pass an error to the callback if you delete something that doesn\'t exist': (test) ->
		db.delete newDocName(), (error) ->
			test.ok error
			test.done()
}

# Events
exports.events = testCase {
	setUp: (callback) ->
		@name = newDocName()
		callback()

	'emit events when ops are applied': (test) ->
		expectedVersions = [0...2]
		events.listen @name, ((v) -> test.strictEqual v, 0), (delta) ->
			test.strictEqual delta.version, expectedVersions.shift()
			test.done() if expectedVersions.length == 0

		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)
	
	'emit transformed events when old ops are applied': (test) ->
		expectedVersions = [0...3]
		events.listen @name, ((v) -> test.strictEqual v, 0), (delta) ->
			test.strictEqual delta.version, expectedVersions.shift()
			test.done() if expectedVersions.length == 0

		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) =>
				test.ifError(error)
				db.applyDelta @name, {version:1, op:{position: 0, text: 'hi2'}}, (error, v) ->
					test.ifError(error)
					test.strictEqual v, 2
	
	'emit events when ops are applied to an existing document': (test) ->
		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)

		expectedVersions = [2...4]
		events.listen @name, ((v) -> test.strictEqual v, 2), (delta) ->
			test.strictEqual delta.version, expectedVersions.shift()
			test.done() if expectedVersions.length == 0

		applyOps @name, 2, [
				{position: 0, text: 'Hi'}
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)

	'emit events with listenFromVersion from before the first version': (test) ->
		expectedVersions = [0...2]
		events.listenFromVersion @name, 0, (delta) ->
			test.strictEqual delta.version, expectedVersions.shift()
			test.done() if expectedVersions.length == 0

		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)

	'emit events with listenFromVersion from the first version after its been sent': (test) ->
		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)

		expectedVersions = [0...2]
		events.listenFromVersion @name, 0, (delta) ->
			test.strictEqual delta.version, expectedVersions.shift()
			test.done() if expectedVersions.length == 0
	
	'emit events with listenFromVersion from the current version': (test) ->
		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)

		expectedVersions = [2...4]
		events.listenFromVersion @name, 2, (delta) ->
			test.strictEqual delta.version, expectedVersions.shift()
			test.done() if expectedVersions.length == 0

		applyOps @name, 2, [
				{position: 0, text: 'Hi'}
				{position: 0, text: 'Hi'}
			], (error, _) -> test.ifError(error)

	'stop emitting events after removeListener is called': (test) ->
		listener = (delta) =>
			test.strictEqual delta.version, 0, 'Listener was not removed correctly'
			events.removeListener @name, listener

		events.listen @name, ((v) -> test.strictEqual v, 0), listener

		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) ->
				test.ifError(error)
				test.done()

	'stop emitting events after removeListener is called when using listenFromVersion': (test) ->
		listener = (delta) =>
			test.strictEqual delta.version, 0, 'Listener was not removed correctly'
			events.removeListener @name, listener

		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'Hi'}
			], (error, _) =>
				test.ifError(error)
				events.listenFromVersion @name, 0, listener
				test.done()
}

# Frontend tests
exports.frontend = testCase {
	'return 404 when on GET on a random URL': (test) ->
		fetch 'GET', "/#{newDocName()}", null, (res, data) ->
			test.strictEqual(res.statusCode, 404)
			test.done()
	
	'PUT returns 405': (test) ->
		fetch 'PUT', "/#{newDocName()}", null, (res, data) ->
			test.strictEqual res.statusCode, 405
			# These might be in a different order... this will do for now.
			test.strictEqual res.headers.allow, 'GET,POST,DELETE'
			test.done()

	'POST a document in the DB returns 200 OK': (test) ->
		fetch 'POST', '/M?v=0', {type:'simple'}, (res, data) ->
			test.strictEqual res.statusCode, 200
			test.deepEqual JSON.parse(data), {v:0}

			fetch 'POST', '/M?v=1', {position: 0, text: 'Hi'}, (res, data) ->
				test.strictEqual res.statusCode, 200
				test.deepEqual JSON.parse(data), {v:1}
				fetch 'GET', '/M', null, (res, data) ->
					test.strictEqual res.statusCode, 200
					test.deepEqual JSON.parse(data), {v:2, type:'simple', snapshot:{str: 'Hi'}}
					test.done()
		

	'POST a document with no version returns 400': (test) ->
		fetch 'POST', '/N', {type:'simple'}, (res, data) ->
			test.strictEqual res.statusCode, 400
			test.done()

	'POST a document with invalid JSON returns 400': (test) ->
		fetch 'POST', '/O?v=0', 'invalid>{json', (res, data) ->
			test.strictEqual res.statusCode, 400
			test.done()
	
	'DELETE deletes a document': (test) ->
		db.applyDelta 'P', {version:0, op:{type:'simple'}}, (error, newVersion) ->
			test.ifError(error)
			fetch 'DELETE', '/P', null, (res, data) ->
				test.strictEqual res.statusCode, 200
				test.done()
	
	'DELETE returns a 404 message if you delete something that doesn\'t exist': (test) ->
		fetch 'DELETE', '/Q', null, (res, data) ->
			test.strictEqual res.statusCode, 404
			test.done()
}

exports.stream = testCase {
	setUp: (callback) ->
		@name = newDocName()

		# Make a new socket.io socket connected to the server's stream interface
		@socket = new clientio.Socket hostname, {port: port}
		@socket.connect()
		@socket.on 'connect', () -> callback()
	
	tearDown: (callback) ->
		@socket.disconnect()
		callback()

	'be able to open a document': (test) ->
		@socket.send {doc:@name, v:0, open:true}
		expectData @socket, [{doc:@name, v:0, open:true}], ->
			test.done()
	
	'be able to open a document with no version specified': (test) ->
		@socket.send {doc:@name, open:true}
		@socket.on 'message', (data) =>
			test.deepEqual data, {doc:@name, v:0, open:true}
			test.done()
	
	'be able to open a document at a previous version and get ops since': (test) ->
		db.applyDelta @name, {version:0, op:{type:'simple'}}, (error, newVersion) =>
			test.ifError(error)

			@socket.send {doc:@name, v:0, open:true}
			expectData @socket, [{doc:@name, v:0, open:true}, {v:0, op:{type:'simple'}}], ->
				test.done()

	'be able to receive ops through an open @socket': (test) ->
		@socket.send {doc:@name, v:0, open:true}
		expectData @socket, [{doc:@name, v:0, open:true}], =>
			applyOps @name, 0, [{type:'simple'}], (error, _) =>
				test.ifError(error)

				expectData @socket, [{v:0, op:{type:'simple'}}], ->
					test.done()

	'be able to send an op': (test) ->
		events.listen @name, ((v) -> test.strictEqual v, 0), (delta) =>
			test.strictEqual delta.version, 0
			test.deepEqual delta.op, {type:'simple'}
			test.done()

		@socket.send {doc:@name, v:0, op:{type:'simple'}}

	'receive confirmation when an op is sent': (test) ->
		expectData @socket, [{doc:@name, v:0}], () =>
			test.done()

		@socket.send {doc:@name, v:0, op:{type:'simple'}}

	'not be sent your own ops back': (test) ->
		@socket.on 'message', (data) ->
			test.notDeepEqual data.op, {type:'simple'} if data.op?

		expectData @socket, [{doc:@name, v:0, open:true}, {v:0}], =>
			# Gonna do this a dodgy way. Because I don't want to wait an undefined amount of time
			# to make sure the op doesn't come, I'll trigger another op and make sure it recieves that.
			# The second op should come after the first.
			applyOps @name, 0, [{position:0, text:'hi'}], (error, _) =>
				expectData @socket, [{v:1, op:{position:0, text:'hi'}}], ->
				test.done()

		@socket.send {doc:@name, v:0, open:true}
		@socket.send {doc:@name, v:0, op:{type:'simple'}}

	'get a document snapshot': (test) ->
		applyOps @name, 0, [
				{type: 'simple'},
				{position: 0, text: 'internet'}
			], (error, _) =>
				test.ifError(error)

				@socket.send {doc:@name, snapshot:null}
				@socket.on 'message', (data) =>
					test.deepEqual data, {doc:@name, snapshot:{str:'internet'}, v:2, type:'simple'}
					test.done()

	'get a null snapshot when getting a nonexistent document': (test) ->
		@socket.send {doc:@name, snapshot:null}
		@socket.on 'message', (data) =>
			test.deepEqual data, {doc:@name, snapshot:null, type:null, v:0}
			test.done()
	
	'be able to close a document': (test) ->
		name1 = newDocName()
		name2 = newDocName()

		@socket.send {doc:name1, open:true}
		@socket.send {open:false}
		@socket.send {doc:name2, open:true}

		expectData @socket, [{doc:name1, open:true, v:0}, {open:false}, {doc:name2, open:true, v:0}], =>
			# name1 should be closed, and name2 should be open.
			# We should only get the op for name2.
			db.applyDelta name1, {version:0, op:{type:'simple'}}, (error, appliedVersion) ->
				test.ifError(error)
			db.applyDelta name2, {version:0, op:{type:'text'}}, (error, appliedVersion) ->
				test.ifError(error)

			expectData @socket, [{v:0, op:{type:'text'}}], ->
				test.done()
}


# Type tests
exports.type = {
	'test.done text type tests': (test) ->
		types.text.test()
		randomizer.test(types.text)
		test.done()
}

# Client stream tests
exports.clientstream = testCase {
	setUp: (callback) ->
		@name = newDocName()
		@ds = new DeltaStream hostname, port
		callback()

	tearDown: (callback) ->
		@ds.disconnect()
		callback()

	'open a document': (test) ->
		@ds.open @name, 0, (msg) =>
			test.deepEqual msg, {doc:@name, open:true, v:0}
			test.done()
	
	'submit an op': (test) ->
		@ds.open @name, 0, (msg) =>
			@ds.submit @name, {type:'simple'}, 0, (msg) =>
				test.deepEqual msg, {v:0, doc:@name}
				test.done()
	
	'have a docname with the op even when the server skips it': (test) ->
		@ds.submit @name, {type:'simple'}, 0, (msg) =>
			test.deepEqual msg, {v:0, doc:@name}
			@ds.submit @name, {position:0, text:'hi'}, 1, (msg) =>
				test.deepEqual msg, {v:1, doc:@name}
				test.done()

	'get an empty document returns a null snapshot': (test) ->
		@ds.get @name, (msg) =>
			test.deepEqual msg, {doc:@name, v:0, type:null, snapshot:null}
			test.done()

	'get a non-empty document gets its snapshot': (test) ->
		@ds.submit @name, {type:'simple'}, 0, =>
			@ds.get @name, (msg) =>
				test.deepEqual msg, {doc:@name, v:1, type:'simple', snapshot:{str:''}}
				test.done()

	'get a stream of ops for an open document': (test) ->
		@ds.open @name, 0, (msg) =>
			db.applyDelta @name, {version:0, op:{type:'simple'}}, (error, appliedVersion) ->
				test.ifError(error)
				test.strictEqual appliedVersion, 0

		@ds.on @name, 'op', (data) =>
			test.deepEqual data, {doc:@name, v:0, op:{type:'simple'}}
			test.done()

	'not get ops sent after the document was closed': (test) ->
		@ds.open @name, 0, (msg) =>
			@ds.close @name, =>
				# The document should now be closed.
				db.applyDelta @name, {version:0, op:{type:'simple'}}, (error, appliedVersion) =>
					# We shouldn't get that op...
					@ds.open newDocName(), 0, (msg) ->
						test.done()

		@ds.on @name, 'op', (data) ->
			throw new Error "Received op for closed document: #{i data}"
	
	'submit a set type op on a doc that already has a type returns the right error code': (test) ->
		@ds.submit @name, {type:'simple'}, 0, =>
			@ds.submit @name, {type:'text'}, 0, (msg) =>
				test.deepEqual msg, {doc:@name, v:null, error:'Type already set'}
				test.done()

	'submit sets a type op with a foreign type': (test) ->
		@ds.submit @name, {type:'oogedy boogedy'}, 0, (msg) ->
			# There should be a way to detect this.
			test.strictEqual msg.v, null
			test.done()
}

exports.client = testCase {
	setUp: (callback) ->
		@c = new client.Connection(hostname, port)
		@name = newDocName()
		callback()
	
	tearDown: (callback) ->
		@c.disconnect()
		callback()

	'create connection': (test) ->
		test.ok @c
		test.done()
	
	'create a new document': (test) ->
		@c.getOrCreate @name, 'text', (doc, error) =>
			test.ok doc
			test.ifError error

			test.strictEqual doc.name, @name
			test.strictEqual doc.type, types.text
			test.strictEqual doc.version, 1
			test.done()

	'open a document that is already open': (test) ->
		@c.getOrCreate @name, 'text', (doc1, error) =>
			test.ifError error
			test.ok doc1
			test.strictEqual doc1.name, @name
			@c.getOrCreate @name, 'text', (doc2, error) =>
				test.strictEqual doc1, doc2
				test.done()
	
	'open a document that already exists': (test) ->
		db.applyDelta @name, {version:0, op:{type:'text'}}, (error, appliedVersion) =>
			test.ifError(error)

			@c.getOrCreate @name, 'text', (doc, error) =>
				test.ifError error
				test.ok doc

				test.strictEqual doc.type.name, 'text'
				test.strictEqual doc.version, 1
				test.done()

	'open a document with a different type': (test) ->
		db.applyDelta @name, {version:0, op:{type:'simple'}}, (error, appliedVersion) =>
			test.ifError(error)

			@c.getOrCreate @name, 'text', (doc, error) =>
				test.ok error
				test.strictEqual doc, null
				test.done()
	
	'submit an op to a document': (test) ->
		@c.getOrCreate @name, 'text', (doc, error) =>
			test.ifError error
			test.strictEqual doc.name, @name

			doc.submitOp [{i:'hi'}], =>
				test.deepEqual doc.snapshot, 'hi'
				test.strictEqual doc.version, 2
				test.done()

			# The document should be updated immediately.
			test.strictEqual doc.snapshot, 'hi'
			test.strictEqual doc.version, 1
	
	'infer the version when submitting an op': (test) ->
		@c.getOrCreate @name, 'text', (doc, error) =>
			test.ifError error
			test.strictEqual doc.name, @name

			doc.submitOp [{i:'hi'}], =>
				test.deepEqual doc.snapshot, 'hi'
				test.strictEqual doc.version, 2
				test.done()
	
	'compose multiple ops together when they are submitted while an op is in flight': (test) ->
		@c.getOrCreate @name, 'text', (doc, error) =>
			test.ifError error
			test.strictEqual doc.name, @name

			doc.submitOp [{i:'hi'}], ->
				test.strictEqual doc.version, 2

			doc.submitOp [2, {i:'hi'}], ->
				test.strictEqual doc.version, 3
			doc.submitOp [4, {i:'hi'}], ->
				test.strictEqual doc.version, 3
				test.expect 5
				test.done()
	
	'Receive submitted ops': (test) ->
		@c.getOrCreate @name, 'text', (doc, error) =>
			test.ifError error
			test.strictEqual doc.name, @name

			doc.onChanged (op) ->
				test.deepEqual op, [{i:'hi'}]

				test.expect 4
				test.done()

			db.applyDelta @name, {version:1, op:[{i:'hi'}]}, (error, appliedVersion) ->
				test.ifError error

	'get a nonexistent document passes null to the callback': (test) ->
		@c.get newDocName(), (doc) ->
			test.strictEqual doc, null
			test.done()
	
	'get an existing document returns the document': (test) ->
		db.applyDelta @name, {version:0, op:{type:'text'}}, (error, appliedVersion) =>
			test.ifError(error)

			@c.get @name, (doc) =>
				test.ok doc

				test.strictEqual doc.name, @name
				test.strictEqual doc.type.name, 'text'
				test.strictEqual doc.version, 1
				test.done()
}

exports.integration = {
	'ops submitted on one document get sent to another': (test) ->
		c1 = new client.Connection(hostname, port)
		c2 = new client.Connection(hostname, port)
		
		# We'll open the same document through both connections.
		name = newDocName()
		doc1 = c1.getOrCreate name, 'text', (doc1, error) ->
			test.ok doc1
			test.ifError error
			test.strictEqual doc1.name, name

			c2.get name, (doc2) ->
				test.ok doc2
				test.strictEqual doc2.name, name
				test.strictEqual doc2.type.name, 'text'
				test.strictEqual doc2.version, 1

				doc1.submitOp [{i:'hi'}]

				doc2.onChanged (op) ->
					test.deepEqual op, [{i:'hi'}]
					test.strictEqual doc2.snapshot, 'hi'
					test.strictEqual doc2.version, 2
					test.done()

	'same document opened through 2 connections works': (test) ->
		test.done()
}