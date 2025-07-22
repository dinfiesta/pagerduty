#!/bin/bash


# PagerDuty API token (replace with your actual token)
API_TOKEN=""
USER_EMAIL=""
PD_SUBDOMAIN=""  # <-- Set your PagerDuty subdomain here
PD_API="https://api.pagerduty.com/incidents"
EMAIL_TO=""

EMAIL_SUBJECT="PagerDuty Incidents - Last 12 Hours (Zulu Time)"
HTML_FILE="/tmp/pagerduty_incidents.html"
ROWS_FILE="/tmp/pagerduty_incident_rows.html"

UNTIL=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SINCE=$(date -u -d "12 hours ago" +"%Y-%m-%dT%H:%M:%SZ")

convert_utc_to_dublin() {
  TZ="Europe/Dublin" date -d "$1" "+%Y-%m-%d %H:%M:%S"
}

is_business_hours() {
  # $1: UTC datetime string (e.g., 2025-06-13T08:30:00Z)
  # Output: "Yes" if within business hours (Mon-Fri, 08:30-17:30 MAD), else "No"
  mad_time=$(TZ="Europe/Madrid" date -d "$1" "+%u %H:%M")
  weekday=$(echo "$mad_time" | awk '{print $1}')
  hm=$(echo "$mad_time" | awk '{print $2}')
  if [[ "$weekday" -ge 1 && "$weekday" -le 5 ]]; then
    if [[ "$hm" > "08:29" && "$hm" < "17:31" ]]; then
      echo "Yes"
      return
    fi
  fi
  echo "No"
}

# Clear rows file
> "$ROWS_FILE"

# Fetch incidents
incidents=$(curl -s -G "$PD_API" \
  -H "Authorization: Token token=$API_TOKEN" \
  -H "Accept: application/vnd.pagerduty+json;version=2" \
  -H "From: $USER_EMAIL" \
  --data-urlencode "since=$SINCE" \
  --data-urlencode "until=$UNTIL" \
  --data-urlencode "limit=100")

echo "$incidents" | jq -r '.incidents[] | [.id, .title, .status, .created_at, .resolved_at, .service.summary] | @tsv' | \
while IFS=$'\t' read -r id title status created_at resolved_at service; do
  # Convert times
  created_dublin=$(convert_utc_to_dublin "$created_at")
  if [[ -n "$resolved_at" && "$resolved_at" != "null" ]]; then
    resolved_dublin=$(convert_utc_to_dublin "$resolved_at")
  else
    resolved_dublin=""
  fi
  # Incident link
  incident_url="https://${PD_SUBDOMAIN}.eu.pagerduty.com/incidents/$id"
  id_link="<a href=\"$incident_url\">$id</a>"

  # Fetch notes for the incident
  notes_json=$(curl -s -G "https://api.pagerduty.com/incidents/$id/notes" \
    -H "Authorization: Token token=$API_TOKEN" \
    -H "Accept: application/vnd.pagerduty+json;version=2" \
    -H "From: $USER_EMAIL")

  # Find the most recent note added by a human user (user.type == "user")
  latest_human_note=$(echo "$notes_json" | jq -r '
    .notes
    | map(select(.user.type == "user"))
    | sort_by(.created_at)
    | reverse
    | .[0].content // ""
  ')

  # Escape HTML in note (basic)
  latest_human_note=$(echo "$latest_human_note" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

  # Business hours check
  business_hours=$(is_business_hours "$created_at")

  # Add row to temp file
  printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n" \
    "$id_link" "$title" "$status" "$created_dublin" "$resolved_dublin" "$service" "$latest_human_note" "$business_hours" >> "$ROWS_FILE"
done

# Read all rows into a variable
rows=$(cat "$ROWS_FILE")

# Output HTML
cat <<EOF > "$HTML_FILE"
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>PagerDuty Incidents - Last 12 Hours</title>
  <style>
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
    a { color: #1a0dab; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h2>PagerDuty Incidents (Last 12 Hours, Dublin Time)</h2>
  <table>
    <tr>
      <th>ID</th>
      <th>Title</th>
      <th>Status</th>
      <th>Created At (Dublin)</th>
      <th>Resolved At (Dublin)</th>
      <th>Service</th>
      <th>Latest Human Note</th>
      <th>Business Hours</th>
    </tr>
    $rows
  </table>
</body>
</html>
EOF

cat "$HTML_FILE" | mutt -e "my_hdr From:Pagerduty Operations" -e "set content_type=text/html" -s "$EMAIL_SUBJECT" -c XXXXXX@EMAIL.com -c XXXXXX@EMAIL.com "$EMAIL_TO" 

echo "Report Sent!"
