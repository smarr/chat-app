use "assert"
use "cli"
use "collections"
use "time"
use "random"
use "util"
use "math"
use "format"
use "term"

type ClientSeq is Array[Client]
type ChatSeq is Array[Chat]

primitive Post
primitive PostDelivery
primitive Leave
primitive Invite
primitive Compute
primitive Ignore

type Action is
  ( Post
  | PostDelivery
  | Leave
  | Invite
  | Compute
  | Ignore
  | None
  )

type ActionMap is MapIs[Action, U64]

class val BehaviorFactory
  let _compute: U32
  let _post: U32
  let _leave: U32
  let _invite: U32

  new create(compute: U32, post: U32, leave: U32, invite: U32) =>
    _compute = compute
    _post = _compute + post
    _leave = _post + leave
    _invite = _leave + invite

  fun box apply(dice: DiceRoll): (Action | None) =>
    let pick = dice()
    var action: (Action | None) = None

    if pick < _compute then
      action = Compute
    elseif pick < _post then
      action = Post
    elseif pick < _leave then
      action = Leave
    elseif pick < _invite then
      action = Invite
    end

    action

actor Chat
  let _members: ClientSeq
  let _out: OutStream
  var _buffer: Array[(Array[U8] val | None)]

  new create(out: OutStream, initiator: Client) =>
    _members = ClientSeq
    _buffer =  Array[(Array[U8] val | None)]
    _out = out

    _members.push(initiator)

  be post(payload: (Array[U8] val | None), accumulator: Accumulator) =>
    ifdef "_BENCH_NO_BUFFERED_CHATS" then
      None
    else
      _buffer.push(payload)
    end

    if _members.size() > 0 then
      // In distributed settings, which are not Pony,
      // there is a race between bump and forward. Take
      // care!
      accumulator.bump(Post, _members.size())

      for member in _members.values() do
        member.forward(this, payload, accumulator)
      end
    else
      accumulator.stop(Post)
    end

  be join(client: Client, accumulator: Accumulator) =>
    _members.push(client)
    // _out.print("Chat.join #members: " + _members.size().string())

    ifdef not "_BENCH_NO_BUFFERED_CHATS" then
      if _buffer.size() > 0 then
        accumulator.bump(Ignore, _buffer.size())

        for message in _buffer.values() do
          client.forward(this, message, accumulator)
        end
      end
    end

    client.accepted(this, accumulator)

  be leave(client: Client, did_logout: Bool, accumulator: (Accumulator | None)) =>
    for (i, c) in _members.pairs() do
      if c is client then
        _members.remove(i, 1) ; break
      end
    end

    client.left(this, did_logout, accumulator)

actor Client
  let _id: U64
  let _friends: ClientSeq
  let _chats: ChatSeq
  let _directory: Directory
  let _dice: DiceRoll
  let _rand: SimpleRand
  let _out: OutStream

  new create(out: OutStream, id: U64, directory: Directory, seed: U64) =>
    _id = id
    _friends = ClientSeq
    _chats = ChatSeq
    _directory = directory
    _rand = SimpleRand(seed)
    _dice = DiceRoll(_rand)
    _out = out
    // _out.print("Client.created: id="+id.string() + " seed: " + seed.string())

  be befriend(client: Client) =>
    _friends.push(client)
    // _out.print("Client.befrient: " + _id.string() + " #friends: " + _friends.size().string())

  be logout() =>
    // _out.print("Client.logout: " + _id.string() + " #friends: " + _friends.size().string())
    for chat in _chats.values() do
      chat.leave(this, true, None)
    else
      _directory.left(this)
    end

  be left(chat: Chat, did_logout: Bool, accumulator: (Accumulator | None)) =>
    // _out.print("Client.left: " + _id.string() + " didLogout: " + did_logout.string() + " #friends: " + _friends.size().string())
    for (i, c) in _chats.pairs() do
      if c is chat then
        _chats.remove(i, 1) ; break
      end
    end

    if ( _chats.size() == 0 ) and did_logout then
      _directory.left(this)
    else
      match accumulator
      | let accumulator': Accumulator => accumulator'.stop(Leave)
      end
    end

  be accepted(chat: Chat, accumulator: Accumulator) =>
    _chats.push(chat)
    // _out.print("Client.invite: " + _id.string() + " #chats: " + _chats.size().string())
    accumulator.stop(Ignore)

  be forward(chat: Chat, payload: (Array[U8] val | None), accumulator: Accumulator) =>
    // _out.print("Client.forward: " + _id.string())
    accumulator.stop(PostDelivery)

  be act(behavior: BehaviorFactory, accumulator: Accumulator) =>
    let index = _rand.nextInt(_chats.size().u32()).usize()
    let action = behavior(_dice)
    let actionName =
              match action
              | Post    => "Post"
              | Leave   => "Leave"
              | Invite  => "Invite"
              | Compute => "Compute"
              | None    => "None"
              end
    // _out.print("Client.act: " + _id.string() + " #chats: " + _chats.size().string() + " action: " + actionName.string())

    try
      match action
      | Post => _chats(index)?.post(None, accumulator)
      | Leave => _chats(index)?.leave(this, false, accumulator)
      | Compute => Fibonacci(35) ; accumulator.stop(Compute)
      | Invite =>
        let created = Chat(_out, this)

        _chats.push(created)

        // Again convert the set values to an array, in order
        // to be able to use shuffle from rand
        let f = _friends.clone()
        _rand.shuffle[Client](f)

        var invitations: USize = _rand.nextInt(_friends.size().u32()).usize()

        if invitations == 0 then
          invitations = 1
        end

        accumulator.bump(Invite, invitations)

        for k in Range[USize](0, invitations) do
          try created.join(f(k)?, accumulator) end
        end
      else
        // _out.print("Client.act: " + _id.string() + " stop: none 1")
        accumulator.stop(None)
      end
    else
      // _out.print("Client.act: " + _id.string() + " stop: none 2")
      accumulator.stop(None)
    end

actor Directory
  let _clients: ClientSeq
  let _random: SimpleRand
  let _befriend: U32
  var _poker: (Poker | None)
  let _out: OutStream

  new create(out: OutStream, seed: U64, befriend': U32) =>
    _clients = ClientSeq
    // out.print("Directory.create: " + seed.string())
    _random = SimpleRand(seed)
    _befriend = befriend'
    _poker = None
    _out = out

  be login(id: U64) =>
    // _out.print("Dir.login: " + id.string())
    _clients.push(Client(_out, id, this, _random.next()))

  be befriend() =>
    for friend in _clients.values() do
      for client in _clients.values() do
        if (_random.nextInt(100) < _befriend) and (friend isnt client) then
          client.befriend(friend)
          friend.befriend(client)
        end
      end
    end

  be left(client: Client) =>
    for (i, c) in _clients.pairs() do
      if c is client then
        _clients.remove(i, 1) ; break
      end
    end

    if _clients.size() == 0 then
      match _poker
      | let poker: Poker => poker.finished()
      end
    end

  be poke(factory: BehaviorFactory, accumulator: Accumulator) =>
    // _out.print("Dir.poke")
    for client in _clients.values() do
      client.act(factory, accumulator)
    end

  be disconnect(poker: Poker) =>
    // _out.print("Dir.disconnect")
    _poker = poker

    for c in _clients.values() do
      c.logout()
    end

actor Accumulator
  let _poker: Poker
  var _actions: ActionMap iso
  var _start: F64
  var _end: F64
  var _duration: F64
  var _expected: ISize
  var _did_stop: Bool
  let _out: OutStream

  new create(out: OutStream, poker: Poker, expected: USize) =>
    _poker = poker
    _actions = recover ActionMap end
    _start = Time.millis().f64()
    _end = 0
    _duration = 0
    _expected = expected.isize()
    _did_stop = false
    _out = out

  fun ref _count(action: Action) =>
    try
      _actions(action) = _actions(action)? + 1
    else
      _actions(action) = 1
    end
    let identifier =
      match action
      | Post    => "Post"
      | Leave   => "Leave"
      | Invite  => "Invite"
      | Compute => "Compute"
      | None    => "None"
    else
      "nil"
    end
    // _out.print("Accumulator.stop: expected: " + _expected.string() + " action: " + identifier)

  be bump(action: Action, expected: USize) =>
    _count(action)
    _expected = ( _expected + expected.isize() ) - 1
    // _out.print("Accumulator.bump: " + expected.string() +  " _expected: " + _expected.string())

  be stop(action: Action = Ignore) =>
    _count(action)
    _expected = _expected - 1

    if _expected == 0 then
      _end = Time.millis().f64()
      _duration = _end - _start
      _did_stop = true

      _poker.confirm()
    end
    if _expected < 0 then
      _out.print("  ## Accumulator.stop: " + _expected.string())
    end

   be print(poker: Poker, i: USize, j: USize) =>
     poker.collect(i, j, _duration, _actions = recover ActionMap end)

actor Poker
  let _actions: ActionMap
  var _clients: U64
  var _logouts: ISize
  var _confirmations: ISize
  var _turns: U64
  var _iteration: USize
  var _directories: Array[Directory] val
  var _runtimes: Array[Accumulator]
  var _accumulations: ISize
  var _finals: Array[Array[F64]]
  var _factory: BehaviorFactory
  var _bench: (AsyncBenchmarkCompletion | None)
  var _last: Bool
  var _turn_series: Array[F64]
  let _out: OutStream

  new create(out: OutStream, clients: U64, turns: U64, directories: USize, befriend: U32, factory: BehaviorFactory) =>
    _actions = ActionMap
    _clients = clients
    _logouts = 0
    _confirmations = 0
    _turns = turns
    _iteration = 0
    _runtimes = Array[Accumulator]
    _accumulations = 0
    _finals = Array[Array[F64]]
    _factory = factory
    _bench = None
    _last = false
    _turn_series = Array[F64]
    _out = out
    // _out.print("Poker.start. dirSize: " + directories.string())

    let rand = SimpleRand(42)

    _directories = recover
      let dirs = Array[Directory](directories)

      for i in Range[USize](0, directories.usize()) do
        dirs.push(Directory(out, rand.next(), befriend))
      end

      dirs
    end


  be apply(bench: AsyncBenchmarkCompletion, last: Bool) =>
    // _out.print("Poker.start. dirSize: " + _directories.size().string())
    _confirmations = _turns.isize()
    _logouts = _directories.size().isize()
    _bench = bench
    _last = last
    _accumulations = 0

    var turns: U64 = _turns
    var index: USize = 0
    var values: Array[F64] = Array[F64].init(0, _turns.usize())

    _finals.push(values)

    // _out.print("Poker start.login")

    for clientId in Range[U64](0, _clients) do
      try
        index = clientId.usize() % _directories.size()
        _directories(index)?.login(clientId)
      end
    end

    // To make sure that nobody's friendset is empty
    for directory in _directories.values() do
      directory.befriend()
    end

    while ( turns = turns - 1 ) >= 1 do
      let accumulator = Accumulator(_out, this, _clients.usize())

      for directory in _directories.values() do
        directory.poke(_factory, accumulator)
      end

      _runtimes.push(accumulator)
    end

  be confirm() =>
    // _out.print("Poker.confirm")
    _confirmations = _confirmations - 1
    if _confirmations == 0 then
      for d in _directories.values() do
        d.disconnect(this)
      end
    end

    if _confirmations < 0 then
      _out.print("  ## Poker.confirm: " + _confirmations.string())
    end

  be finished() =>
    _logouts = _logouts - 1
    // _out.print("Poker.finished remaining logouts=" + _logouts.string())

    if _logouts == 0 then
      var turn: USize = 0

      for accumulator in _runtimes.values() do
        _accumulations = _accumulations + 1
        // accumulator.print(this, _iteration, turn)
        turn = turn + 1
      end

      _runtimes = Array[Accumulator]
    end

    if _logouts < 0 then
      _out.print("  ## Poker.finished: " + _logouts.string())
    end

  be collect(i: USize, j: USize, duration: F64, actions: ActionMap val) =>
    // _out.print("Poker.collect: accumulations=" + _accumulations.string())
    for (key, value) in actions.pairs() do
      try
        _actions(key) = value + _actions(key)?
      else
        _actions(key) = value
      end
    end

    try
      _finals(i)?(j)? = duration
      _turn_series.push(duration)
    end

    _accumulations = _accumulations - 1
    if _accumulations < 0 then
      _out.print("  ## Poker.collect: " + _accumulations.string())
    end

    if _accumulations == 0 then
      // _out.print("Poker.collect: ==1 accumulations=" + _accumulations.string())
      _iteration = _iteration + 1

      for (key, value) in _actions.pairs() do
        // could make 'Actions' stringable
        let identifier =
          match key
          | Post    => "Post"
          | Leave   => "Leave"
          | Invite  => "Invite"
          | Compute => "Compute"
          | None    => "None"
          else
            "null"
          end

        _out.print(
          "".join([
              Format(identifier where width = 8)
              Format(value.string() where width = 10, align = AlignRight)
            ].values()
          )
        )
      end

      match _bench
      | let bench: AsyncBenchmarkCompletion => bench.complete()

        if _last then
          let stats = SampleStats(_turn_series = Array[F64])
          var turns = Array[Array[F64]]
          var qos = Array[F64]

          for k in Range[USize](0, _turns.usize()) do
            try
              turns(k)?
            else
              turns.push(Array[F64])
            end

            for iter in _finals.values() do
              try turns(k)?.push(iter(k)?) end
            end
          end

          for l in Range[USize](0, turns.size()) do
            try qos.push(SampleStats(turns.pop()?).stddev()) end
          end

          bench.append(
            "".join(
              [ ANSI.bold()
                Format("" where width = 31)
                Format("j-mean" where width = 18, align = AlignRight)
                Format("j-median" where width = 18, align = AlignRight)
                Format("j-error" where width = 18, align = AlignRight)
                Format("j-stddev" where width = 18, align = AlignRight)
                Format("quality of service" where width = 32, align = AlignRight)
                ANSI.reset()
              ].values()
            )
          )

          bench.append(
            "".join([
                Format("Turns" where width = 31)
                Format(stats.mean().string() + " ms" where width = 18, align = AlignRight)
                Format(stats.median().string() + " ms" where width = 18, align = AlignRight)
                Format("±" + stats.err().string() + " %" where width = 18, align = AlignRight)
                Format(stats.stddev().string() where width = 18, align = AlignRight)
                Format(SampleStats(qos = Array[F64]).median().string() where width = 32, align = AlignRight)
              ].values()
            )
          )

          bench.append("")

          for (key, value) in _actions.pairs() do
            // could make 'Actions' stringable
            let identifier =
              match key
              | Post         => "Post"
              | PostDelivery => "PostDelivery"
              | Leave        => "Leave"
              | Invite       => "Invite"
              | Compute      => "Compute"
              | Ignore       => "Ignore"
              | None         => "None"
              end

            bench.append(
              "".join([
                  Format(identifier where width = 16)
                  Format(value.string() where width = 10, align = AlignRight)
                ].values()
              )
            )
          end
        end
      end
    end

class iso ChatApp is AsyncActorBenchmark
  var _clients: U64
  var _turns: U64
  var _factory: BehaviorFactory val
  var _poker: Poker
  var _invalid_args: Bool

  new iso create(env: Env, cmd: Command val) =>
    _clients = cmd.option("clients").u64()
    _turns = cmd.option("turns").u64()
    _invalid_args = false

    let directories: USize = cmd.option("directories").u64().usize()
    let compute: U32 = cmd.option("compute").u64().u32()
    let post: U32 = cmd.option("post").u64().u32()
    let leave: U32 = cmd.option("leave").u64().u32()
    let invite: U32 = cmd.option("invite").u64().u32()
    let befriend: U32 = cmd.option("befriend").u64().u32()

    let sum = compute + post + leave + invite

    _invalid_args  =
      if sum != 100 then
        env.out.print("Invalid arguments! Sum of probabilities != 100.")
        env.exitcode(-1)
        true
      else
        false
      end

    _factory = recover BehaviorFactory(compute, post, leave, invite) end

    _poker = Poker(env.out, _clients, _turns, directories, befriend, _factory)

  fun box apply(c: AsyncBenchmarkCompletion, last: Bool) =>
    if _invalid_args == false then
      _poker(c, last)
    else
      c.abort()
    end

  fun tag name(): String => "Chat App"

actor Main is BenchmarkRunner
  new create(env: Env) =>
    try
      let cs =
        recover
          CommandSpec.leaf("chat-app", "Cross Language Actor Benchmark", [
            OptionSpec.u64("clients", "The number of clients. Defaults to 1024."
              where short' = 'c', default' = U64(1024))
            OptionSpec.u64("directories", "The number of directories. Defaults to 8."
              where short' = 'd', default' = U64(8))
            OptionSpec.u64("turns", "The number of turns. Defaults to 32."
              where short' = 't', default' = U64(32))
            OptionSpec.u64("compute", "The compute behavior probability. Defaults to 55."
              where short' = 'm', default' = U64(55))
            OptionSpec.u64("post", "The post behavior probability. Defaults to 25."
              where short' = 'p', default' = U64(25))
            OptionSpec.u64("leave", "The leave behavior probability. Defaults to 10."
              where short' = 'l', default' = U64(10))
            OptionSpec.u64("invite", "The invite behavior probability. Defaults to 10."
              where short' = 'i', default' = U64(10))
            OptionSpec.u64("befriend", "The befriend probability. Defaults to 10."
              where short' = 'b', default' = U64(10))
            OptionSpec.bool("parseable", "Generate parseable output. Defaults to false."
              where short' = 's', default' = false)
          ])? .> add_help()?
        end

      let result = recover val CommandParser(consume cs).parse(env.args, env.vars) end

      match result
      | let cmd: Command val => Runner(env, this, cmd)
      | let help: CommandHelp val => help.print_help(env.out) ; env.exitcode(0)
      | let err: SyntaxError val => env.out.print(err.string()) ; env.exitcode(1)
      end
    else
      env.exitcode(-1)
      return
    end

  fun tag benchmarks(bench: Runner, env: Env, cmd: Command val) =>
    bench(32, ChatApp(env, cmd))