#!/bin/bash
# Download one sample photo for the CI tests and make sure it really is a photo.
# usage: get.sh <destination file> <url> <minimum size in bytes>
# curl -f makes HTTP errors fail instead of saving an error page as the "photo"; it retries a few times because the
# sample servers (raw.pixls.us, wikimedia) are sometimes slow. A failure here is a network problem, not a code problem.
dest="$1"; url="$2"; min="${3:-1000}"
for i in 1 2 3 4 5; do
  if curl -fsSL --max-time 180 -o "$dest" "$url" && [ "$(wc -c < "$dest" | tr -d ' ')" -ge "$min" ]; then
    echo "got $dest ($(wc -c < "$dest" | tr -d ' ') bytes)"
    exit 0
  fi
  echo "download attempt $i for $dest failed, retrying"
  sleep $((i * 6))
done
echo "::error::INFRA: could not download sample $dest from $url (network problem, not a code problem)"
exit 1
