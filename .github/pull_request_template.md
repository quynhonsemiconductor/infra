## Description
<!-- What platform infrastructure change does this PR introduce? -->

## Type of change
- [ ] New module
- [ ] Modification to existing resource
- [ ] Deletion / decommission
- [ ] CI/CD change

## Environments affected
- [ ] `live/bootstrap` (account-level: OIDC provider, state backend)

## OpenTofu Plan
<details>
<summary>Plan output</summary>

```hcl
# Paste here
```

</details>

## Blast radius
<!-- What other products/teams could be affected? This repo manages account-level shared resources. -->

## Rollback plan

## Checklist
- [ ] `tofu validate` passes locally
- [ ] Plan output reviewed — no unexpected resource deletions
- [ ] No credentials hardcoded (all values from AWS Secrets Manager / vars)
- [ ] Impact on rova and opshub assessed
