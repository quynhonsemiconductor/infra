# jq helpers shared by aws-orphan-audit.sh and its tests. ep turns an AWS timestamp into UTC epoch seconds:
# the CLI prints the machine's local offset (+07:00, -0500, Z), sometimes with fractional seconds, so the offset
# is parsed, not assumed. Numbers pass through. eks is true when a resource carries an EKS or Karpenter tag.
def ep:
  if type == "number" then .
  else
    capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
    | ($m.d | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $base
    | ($m.z // "Z") as $z
    | if $z == "Z" then $base
      else ($z[0:1]) as $sign
        | (($z[1:3] | tonumber) * 3600 + ($z[-2:] | tonumber) * 60) as $off
        | if $sign == "+" then $base - $off else $base + $off end
      end
  end;
def eks: ([.Tags[]?.Key] | join(" ")) | test("kubernetes.io/cluster|karpenter.sh|eks:"; "i");
