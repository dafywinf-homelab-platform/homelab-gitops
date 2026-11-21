# Sealed Secrets helpers. The controller runs in the cluster (apps/platform/secrets/); the public certificate is
# committed (sealed-secrets/pub-cert.pem) and the private key is backed up outside Git, in ~/.homelab.
SEALING_KEY_BACKUP ?= $(HOME)/.homelab/sealed-secrets-key.json

.PHONY: help seal seal-jenkins-admin fetch-cert backup-sealing-key restore-sealing-key

help:
	@echo "make seal NAMESPACE=<ns> NAME=<secret> KEYS='<key> ...' OUT=<file>  seal a Secret (prompts for values)"
	@echo "make seal-jenkins-admin   re-seal the Jenkins admin login"
	@echo "make fetch-cert           refresh sealed-secrets/pub-cert.pem from the cluster"
	@echo "make backup-sealing-key   copy the controller's private key to $(SEALING_KEY_BACKUP)"
	@echo "make restore-sealing-key  put that key back into a rebuilt cluster and restart the controller"

seal:
	@test -n "$(NAMESPACE)" -a -n "$(NAME)" -a -n "$(KEYS)" -a -n "$(OUT)" || \
		{ echo "usage: make seal NAMESPACE=<ns> NAME=<secret> KEYS='<key> ...' OUT=<file>"; exit 2; }
	@scripts/seal-secret.sh $(NAMESPACE) $(NAME) $(OUT) $(KEYS)

seal-jenkins-admin:
	@scripts/seal-secret.sh jenkins jenkins-admin apps/platform/ci/jenkins-extras/jenkins-admin.sealedsecret.yaml \
		jenkins-admin-user jenkins-admin-password

fetch-cert:
	kubeseal --fetch-cert > sealed-secrets/pub-cert.pem

backup-sealing-key:
	@umask 077; mkdir -p $(dir $(SEALING_KEY_BACKUP))
	@# Strip server-set fields (uid, resourceVersion, ...) so the backup can be applied to a new cluster
	@kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o json \
		| jq '.items |= map(del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields))' \
		> $(SEALING_KEY_BACKUP)
	@chmod 600 $(SEALING_KEY_BACKUP)
	@echo "private key saved to $(SEALING_KEY_BACKUP); keep a second copy somewhere safe"

restore-sealing-key:
	kubectl apply -f $(SEALING_KEY_BACKUP)
	kubectl -n kube-system rollout restart deployment/sealed-secrets-controller
	kubectl -n kube-system rollout status deployment/sealed-secrets-controller
