function emit_rule(    idpart,msgpart,plpart,id,msg,pl) {
  id=""
  msg=""
  pl="-"

  if (match(block, /id:[[:space:]]*[0-9]+/)) {
    idpart=substr(block, RSTART, RLENGTH)
    sub(/^id:[[:space:]]*/, "", idpart)
    id=idpart
  }
  if (match(block, /msg:'[^']*'/)) {
    msgpart=substr(block, RSTART, RLENGTH)
    sub(/^msg:'/,"",msgpart)
    sub(/'$/,"",msgpart)
    msg=msgpart
  }
  if (match(block, /tag:'paranoia-level\/[1-4]'/)) {
    plpart=substr(block, RSTART, RLENGTH)
    sub(/^.*paranoia-level\//,"",plpart)
    sub(/'.*$/,"",plpart)
    pl=plpart
  }

  if (id != "" && msg != "") {
    gsub(/\\/, "", msg)
    print id "\t" source "\t" pl "\t" msg
  }
  block=""
  collecting=0
}

FNR == 1 {
  source=FILENAME
  sub(/^.*\//, "", source)
  sub(/\.conf$/, "", source)
}

/^[[:space:]]*(SecRule|SecAction)[[:space:]]/ {
  if (collecting) emit_rule()
  block=$0
  collecting=($0 ~ /\\[[:space:]]*$/)
  if (!collecting) emit_rule()
  next
}

collecting {
  block=block " " $0
  if ($0 !~ /\\[[:space:]]*$/) emit_rule()
}

END {
  if (collecting) emit_rule()
}
