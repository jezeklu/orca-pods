# Security policy

orca-pods is an isolation tool, so a way around its boundaries is a security issue. The boundaries are listed in the README under "Client security boundary" and "Server security boundary". What is listed there as not protected is a known limitation, not a vulnerability.

## Reporting

Report privately through **Security → Report a vulnerability** on the GitHub repository. Please do not open a public issue.

Include the host distribution, the Podman version, the steps to reproduce and what the container could reach or change. You should get an answer within a week.

## Supported versions

Only the latest release and the latest images (`client`, `server`) get fixes.
