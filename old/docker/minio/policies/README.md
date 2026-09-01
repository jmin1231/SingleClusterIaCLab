# IAM policy templates

Committed, with the bucket name substituted per account at apply time. 5.1 is
explicit about why these are files rather than JSON inlined in a script:

> a policy you can read in a diff is a policy someone can review.

`${STATE_BUCKET}` / `${IMAGES_BUCKET}` are filled by `envsubst` from
`minio-provision.sh`, the same allow-list pattern `proxy-installer.sh` uses so
substitution cannot reach anything it was not meant to.

**Enterprise equivalent:** these are AWS IAM policy documents in all but name.
The same file shape is what Terraform's `aws_iam_policy` or a Kubernetes
`ClusterRole` would carry — reviewed in a diff, applied by automation, never
edited in a console.
