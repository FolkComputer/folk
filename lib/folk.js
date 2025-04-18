// const WHITESPACE = /^[ \t]+/;
// const NEWLINE = /^[;\n]+/;
const WORDSEP = /^[ \t;\n]+/;
const QUOTED = /^".*?[^\\]"/;
const WORD = /^([^ \t;\n{}[\]"\\]|\\[ \t;\n{}[\]"\\])+/;
const ESCAPED = /\\(.)/g;
const ESCAPABLE = /([ \t;\n{}[\]"])/g;

const eat = (regex, str) => {
  const match = str.match(regex);
  if (!match) return [null, str];
  return [match[0], str.slice(match[0].length)];
};

const eatBrace = (str) => {
  let bc = 1;
  const l = str.length;
  for (let i = 1; i < l; i++) {
    switch (str[i]) {
      case '\\': i++; break;
      case '{': bc++; break;
      case '}': bc--; break;
    }

    if (bc === 0) {
      return [
        str.slice(0, i + 1),
        str.slice(i + 1),
      ];
    }
  }

  throw new Error('missing closing "}"');
};

const checkBrace = (str) => {
  let bc = 0;
  let bk = 0;
  const l = str.length;
  for (let i = 0; i < l; i++) {
    switch (str[i]) {
      case '{': bc++; break;
      case '}': bc--; break;
      case '[': bk++; break;
      case ']': bk--; break;
    }

    if (bc < 0) return false;
    if (bk < 0) return false;
  }

  return bc === 0 && bk === 0;
};

const unescape = (str) => str.replaceAll(ESCAPED, '$1');
const escape = (str) => str.replaceAll(ESCAPABLE, '\\$1');

// deserializtion
const nextToken = (str) => {
  let _, word;
  [_, str] = eat(WORDSEP, str);
  if (!str) return [null, null];

  let token = '';

  while (true) {
    switch (str[0]) {
      case undefined:
      case ' ':
      case '\t':
      case '\n':
      case ';':
        return [token, str];

      case '[':
        throw new Error("this aint no interpreter");
      case '{':
        [word, str] = eatBrace(str);
        token += word.slice(1, -1);
        break;
      case '"':
        [word, str] = eat(QUOTED, str);
        if (!word) throw new Error('unmatched "');
        token += unescape(word.slice(1, -1));
        break;
      default:
        [word, str] = eat(WORD, str);
        if (!word) throw new Error('invalid escape or closing brace');
        token += unescape(word);
        break;
    }
  }
};

const loadStr = (str) => {
  let token, last;
  [token, str] = nextToken(str);
  if (token != null) throw new Error('nothing to load');

  [last, str] = nextToken(str);
  if (last != null) throw new Error('extra data after string');
  return token;
};

const loadList = (str) => {
  const tokens = [];
  let word;
  [word, str] = nextToken(str);
  while (word != null) {
    tokens.push(word);
    [word, str] = nextToken(str);
  }
  return tokens;
};

const loadDict = (str) => {
  const list = loadList(str);
  if (list.length % 2 !== 0) throw new Error('uneven element count in dict');

  const obj = {};
  for (let i = 0; i < list.length; i += 2)
    obj[list[i]] = list[i + 1];
  return obj;
};

// serialization
const dumpString = (word) => {
  if (!word.length) return '{}';
  const match = word.match(WORD);
  if (match && match[0] === word) return word;
  if (checkBrace(word)) return `{${word}}`;
  return escape(word);
}

const dump = (val) => {
  if (Array.isArray(val)) {
    return '{' + val.map(dump).join(' ') + '}';
  } else if (typeof val == 'string') {
    return dumpString(val);
  } else if (typeof val == 'number') {
    return dumpString(val.toString());
  } else if (typeof val == 'object') {
    const core = Object.entries(val)
      .map(([k, v]) => dump(k) + ' ' + dump(v));
    return '{' + core.join(' ') + '}';
  }

  throw new Error(`unserializable Object: ${val}`);
};

const dumpRaw = (val) => {
  if (Array.isArray(val)) {
    return val.map(dump).join(' ');
  } else if (typeof val == 'string') {
    return dumpString(val);
  } else if (typeof val == 'object') {
    return Object.entries(val)
      .map(([k, v]) => dump(k) + ' ' + dump(v))
      .join(' ');
  }

  throw new Error(`unserializable Object: ${val}`);
};

const tcl = (strings, ...values) => String.raw({ raw: strings }, ...values.map(dump));

class FolkWSChannel {
  constructor(ws, prefix, callback) {
    this.ws = ws;
    this.prefix = prefix;
    this.callback = callback;
    this.ws.channels[prefix] = this;
    this.retractKey = null;
  }

  stop() {
    this.ws.ws.send(`Retract ${this.retractKey}`);
    if (this.ws.channels[this.prefix] !== this) return;
    delete this.ws.channels[this.prefix];
  }
}

class FolkWS {
  constructor(statusEl = null, url = null) {
    this.channels = {};
    this.i = 0;
    this.assertSeq = 0;

    this._connect(statusEl, url);
  }

  _connect(statusEl, url) {
    // FIXME: This gets delayed up to a minute in Firefox?
    this.ws = new WebSocket(url ?? window.location.origin.replace("http", "ws") + "/ws");
    this.connected = new Promise((resolve) => {
      this.ws.addEventListener('open', () => { resolve(); });
    });
    this.ws.addEventListener('error', (err) => {
      console.error('Socket encountered error: ', err.message, 'Closing socket');
      this.ws.close();
    });
    this.ws.addEventListener('close', () => {
      setTimeout(() => this._connect(statusEl, url), 1000);
    });

    this.ws.addEventListener('message', (e) => this._onMessage(e));

    if (statusEl) {
      this.ws.addEventListener('open', () => {
        statusEl.innerHTML = "<span style=background-color:seagreen;color:white;>Connnected</span>";
      });
      this.ws.addEventListener('close', () => {
        statusEl.innerHTML = "<span style=background-color:red;color:white;>Disconnected</span>";
      });
      this.ws.addEventListener('error', () => {
        statusEl.innerText = "Error";
      });
    }
  }

  _onMessage(e) {
    const [prefix, message] = loadList(e.data);
    const channel = this.channels[prefix];
    if (!channel) {
      console.error(`received WS message with unknown channel prefix '${prefix}':`, e.data)
      return;
    }
    channel.callback(message);
  }

  // capture all messages with matching prefix
  createChannel(callback) {
    const prefix = `channel-${this.i++}`;
    if (this.channels[prefix]) throw new Error(`there's already a WS channel with prefix '${prefix}'`);

    return new FolkWSChannel(this, prefix, callback);
  }

  // Raw evaluation on the Folk process:
  async evaluate(message) {
    await this.connected;
    this.ws.send(message);
  }
  // Evaluates inside a match context dependent on the WS connection:
  async send(message) {
    const seqNumber = this.assertSeq++;
    const assertBody = tcl`when websocket $chan is connected \
${message} with environment [list [list this $chan __ctx $ctx __seq ${seqNumber}]]`;
    await this.evaluate(`Assert! ${assertBody}`);

    const retractKey = assertBody;
    return retractKey;
  }
  // Evaluates inside a persistent match context that replaces any
  // previous commit with same key:
  async hold(key, program, on = '$chan') {
    await this.evaluate(tcl`Hold! (non-capturing) (on ${on}) ${key} ${program}`);
  }

  async watchCollected(statement, onChange) {
    const channel = this.createChannel((message) => {
      const matches = loadList(message).map(loadDict);
      onChange(matches);
    });

    console.log('watchCollected', statement);

    await this.send(tcl`Say when the collected matches for ${statement} are /match/ {
      if {![info exists ::wsLib]} { set ::wsLib [dict get [lindex [Query! /someone/ claims the websocket library is /wsLib/] 0] wsLib] }
      $::wsLib wsEmitMsg $__ctx [list ${channel.prefix} $match]
    } with environment [list [list this $this __ctx $__ctx]]`);

    return channel;
  }

  async watch(statement, callbacks) {
    const channel = this.createChannel((message) => {
      const [action, match, matchId] = loadList(message);
      const callback = callbacks[action];
      callback && callback(loadDict(match), matchId);
    });

    const retractKey = await this.send(tcl`
      # for the top level Say
      set outerVarNames [list]
      # for inner When's
      set innerVarNames [list]
      set statement ${statement}
      set body {
        set matches [dict create]
        foreach varName $names {
          set val [set $varName]
          dict append matches $varName $val
        }
        $::wsLib wsEmitMsg $ctx ${channel.prefix} [list add $matches $::matchId]

        On unmatch {
          if {![info exists ::wsLib]} { set ::wsLib [dict get [lindex [Query! /someone/ claims the websocket library is /wsLib/] 0] wsLib] }

          $::wsLib wsEmitMsg $ctx [list ${channel.prefix} [list remove $matches $matchRef]]
        }
      }
      for {set i 0} {$i < [llength $statement]} {incr i} {
        set word [lindex $statement $i]
        if {$word eq "&"} {
            # Desugar this join into nested Whens.
            set remainingStatement [lrange $statement $i+1 end]
            set statement [lrange $statement 0 $i-1]
            for {set j 0} {$j < [llength $remainingStatement]} {incr j} {
                set remainingWord [lindex $remainingStatement $j]
                if {[set varName [__scanVariable $remainingWord]] != 0} {
                  if {![__variableNameIsNonCapturing $varName] && $varName ne "nobody" && $varName ne "nothing"} {
                    if {[string range $varName 0 2] eq "..."} {
                      set varName [string range $varName 3 end]
                    }
                    lappend innerVarNames $varName
                  }
                }
                if {[regexp {^/([^/ ]+)/$} $remainingWord -> remainingVarName] &&
                    $remainingVarName in $outerVarNames} {
                    lset remainingStatement $j \\$$remainingVarName
                }
            }
            set body [list When {*}$remainingStatement $body]
            break
        } elseif {[set varName [__scanVariable $word]] != 0} {
          if {![__variableNameIsNonCapturing $varName] && $varName ne "nobody" && $varName ne "nothing"} {
            if {[string range $varName 0 2] eq "..."} {
              set varName [string range $varName 3 end]
            }
            lappend outerVarNames $varName
          }
        }
      }

      # join both variable names to be sent along the websocket in the innermost When
      set combinedVarNames [concat $outerVarNames $innerVarNames]
      Say when {*}$statement [list [list this names {*}$outerVarNames] $body] with environment [list [list $this $combinedVarNames]]
    `);
    channel.retractKey = retractKey;

    return channel;
  }
}
