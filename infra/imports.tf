# ---------------------------------------------------------------------------
# Terraform import blocks — reconcile resources that exist in AWS but were
# dropped from state when the ALB SG was forced-replaced (HTTPS->HTTP change).
# These blocks run once on the next apply and become no-ops thereafter.
# ---------------------------------------------------------------------------

import {
  id = "sg-087039ab8892e041d"
  to = aws_security_group.alb
}
