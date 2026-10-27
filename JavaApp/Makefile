# Prerequisite variables
SOURCEDIR := src
OUTPUTDIR := build

# Every directory directly under src/ is a target (launcher, lwjgl, ...)
TARGET_NAMES := $(notdir $(shell find $(SOURCEDIR) -mindepth 1 -maxdepth 1 -type d))
TARGETS := $(TARGET_NAMES:%=$(OUTPUTDIR)/%.jar)
# One stamp per target, touched after all of its sources compiled successfully
STAMPS := $(TARGET_NAMES:%=$(OUTPUTDIR)/.%.compiled)

# Add all jars to classpath and allow compiling with private API
JCFLAGS := -cp "$(subst $() $(),:,$(wildcard $(SOURCEDIR)/*/):$(wildcard libs/*/*.jar))" -XDignore.symbol.file

all: $(TARGETS) check_empty_classes
	
# Sometimes the CI produces empty class file resulting in broken jar, so we check and abort here.
# Safety net: runs once everything is built (and as part of each jar rule on that jar's own classes).
check_empty_classes: $(TARGETS)
	@set -e
	@echo "Checking for empty class files"
	@EMPTY="$$(find $(OUTPUTDIR) -name '*.class' -size 0)"; \
	if [ -n "$$EMPTY" ]; then \
		echo "Error: found empty class files: $$EMPTY"; \
		exit 1; \
	fi

# $(call CHECK_EMPTY,dir): fail if dir contains zero-byte class files
define CHECK_EMPTY
EMPTY="$$(find $(1) -name '*.class' -size 0)"; \
	if [ -n "$$EMPTY" ]; then \
		echo "Error: found empty class files in $(1): $$EMPTY"; \
		exit 1; \
	fi
endef

# Each target directory is compiled by exactly ONE javac invocation, writing straight
# into $(OUTPUTDIR)/<target>. Different javac processes must never write the same
# class file (that used to race and produce truncated/empty classes under make -j).
# -implicit:none stops javac from emitting classes for sources it only pulled in
# through the classpath (i.e. sources that belong to another target).
# The source list is evaluated when the recipe runs, so new .java files are picked up
# automatically and are tracked as prerequisites via the find below.
define COMPILE_TARGET
$(OUTPUTDIR)/.$(1).compiled: $$(shell find $(SOURCEDIR)/$(1) -type f -name '*.java')
	@set -e
	@echo "Compiling $(1)"
	@rm -rf $(OUTPUTDIR)/$(1) $$@
	@mkdir -p $(OUTPUTDIR)/$(1)
	@find $(SOURCEDIR)/$(1) -type f -name '*.java' > $(OUTPUTDIR)/.$(1).sources
	@$$(BOOTJDK)/javac $$(JCFLAGS) -implicit:none -d $(OUTPUTDIR)/$(1) @$(OUTPUTDIR)/.$(1).sources
	@touch $$@
endef
$(foreach t,$(TARGET_NAMES),$(eval $(call COMPILE_TARGET,$(t))))

$(OUTPUTDIR)/launcher.jar: $(OUTPUTDIR)/.launcher.compiled
	@set -e
	@$(call CHECK_EMPTY,$(OUTPUTDIR)/launcher)
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cf $@ -C $(basename $@) .

$(OUTPUTDIR)/lwjgl.jar: $(OUTPUTDIR)/.lwjgl.compiled
	@set -e
	@$(call CHECK_EMPTY,$(OUTPUTDIR)/lwjgl)
	@echo "Creating $@"
	@rm -rf $(OUTPUTDIR)/lwjgl_lib
	@mkdir -p $(OUTPUTDIR)/lwjgl_lib
	@cd $(OUTPUTDIR)/lwjgl_lib && find ../../libs/lwjgl -name 'lwjgl*.jar' -exec $(BOOTJDK)/jar -xf {} \; && rm -rf META-INF
	@cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib/
	@$(call CHECK_EMPTY,$(OUTPUTDIR)/lwjgl_lib)
	@$(BOOTJDK)/jar -cf $@ -C $(OUTPUTDIR)/lwjgl_lib .

$(OUTPUTDIR)/patchjna_agent.jar: $(OUTPUTDIR)/.patchjna_agent.compiled
	@set -e
	@$(call CHECK_EMPTY,$(OUTPUTDIR)/patchjna_agent)
	@mv $(basename $@)/com/sun/jna/Platform.class $(basename $@)/com/sun/jna/Platform.class.patch
	@echo "Creating $@"
	@$(BOOTJDK)/jar -cfm $@ $(SOURCEDIR)/patchjna_agent.txt -C $(basename $@) .

clean:
	rm -rf $(OUTPUTDIR)

.SUFFIXES: .java
.PHONY: all clean check_empty_classes
