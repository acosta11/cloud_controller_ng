require 'spec_helper'

module VCAP::CloudController
  RSpec.describe ProcessModel, type: :model do
    let(:org) { Organization.make }
    let(:space) { Space.make(organization: org) }
    let(:parent_app) { AppModel.make(space:) }

    let(:domain) { PrivateDomain.make(owning_organization: org) }
    let(:route) { Route.make(domain:, space:) }

    def enable_custom_buildpacks
      TestConfig.override(disable_custom_buildpacks: nil)
    end

    def disable_custom_buildpacks
      TestConfig.override(disable_custom_buildpacks: true)
    end

    def expect_validator(validator_class)
      expect(subject.validation_policies).to include(an_instance_of(validator_class))
    end

    def expect_no_validator(validator_class)
      matching_validator = subject.validation_policies.select { |validator| validator.is_a?(validator_class) }
      expect(matching_validator).to be_empty
    end

    before do
      VCAP::CloudController::Seeds.create_seed_stacks
    end

    describe 'dataset module' do
      let!(:buildpack_process) { ProcessModel.make }
      let!(:docker_process) { ProcessModel.make(:docker) }

      describe '#buildpack_type' do
        it 'only returns processes associated with a buildpack app' do
          expect(ProcessModel.buildpack_type.map(&:name)).to contain_exactly(buildpack_process.name)
        end
      end

      describe '#non_docker_type' do
        it 'only returns processes not associated with a docker app' do
          expect(ProcessModel.non_docker_type.map(&:name)).to contain_exactly(buildpack_process.name)
        end
      end
    end

    describe 'Creation' do
      subject(:process) { ProcessModel.new }

      it 'has a default instances' do
        schema_default = ProcessModel.db_schema[:instances][:default].to_i
        expect(process.instances).to eq(schema_default)
      end

      it 'has a default memory' do
        TestConfig.override(default_app_memory: 873_565)
        expect(process.memory).to eq(873_565)
      end

      context 'has custom ports' do
        subject(:process) { ProcessModel.make(ports: [8081, 8082]) }

        it 'return an app with custom port configuration' do
          expect(process.ports).to eq([8081, 8082])
        end
      end

      it 'has a default log_rate_limit' do
        TestConfig.override(default_app_log_rate_limit_in_bytes_per_second: 873_565)
        expect(process.log_rate_limit).to eq(873_565)
      end
    end

    describe 'Associations' do
      it { is_expected.to have_timestamp_columns }
      it { is_expected.to have_associated :events, class: AppEvent }

      it 'has service_bindings through the parent app' do
        process  = ProcessModelFactory.make(type: 'potato')
        binding1 = ServiceBinding.make(app: process.app, service_instance: ManagedServiceInstance.make(space: process.space))
        binding2 = ServiceBinding.make(app: process.app, service_instance: ManagedServiceInstance.make(space: process.space))

        expect(process.reload.service_bindings).to contain_exactly(binding1, binding2)
      end

      it 'has route_mappings' do
        process = ProcessModelFactory.make
        route1  = Route.make(space: process.space)
        route2  = Route.make(space: process.space)

        mapping1 = RouteMappingModel.make(app: process.app, route: route1, process_type: process.type)
        mapping2 = RouteMappingModel.make(app: process.app, route: route2, process_type: process.type)

        expect(process.reload.route_mappings).to contain_exactly(mapping1, mapping2)
      end

      it 'has routes through route_mappings' do
        process = ProcessModelFactory.make
        route1  = Route.make(space: process.space)
        route2  = Route.make(space: process.space)

        RouteMappingModel.make(app: process.app, route: route1, process_type: process.type)
        RouteMappingModel.make(app: process.app, route: route2, process_type: process.type)

        expect(process.reload.routes).to contain_exactly(route1, route2)
      end

      it 'has a desired_droplet from the parent app' do
        parent_app = AppModel.make
        droplet    = DropletModel.make(app: parent_app, state: DropletModel::STAGED_STATE)
        parent_app.update(droplet:)
        process = ProcessModel.make(app: parent_app)

        expect(process.desired_droplet).to eq(parent_app.droplet)
      end

      it 'has a space from the parent app' do
        parent_app = AppModel.make(space:)
        process    = ProcessModel.make
        expect(process.space).not_to eq(space)
        process.update(app: parent_app)
        expect(process.reload.space).to eq(space)
      end

      it 'has an organization from the parent app' do
        parent_app = AppModel.make(space:)
        process    = ProcessModel.make
        expect(process.organization).not_to eq(org)
        process.update(app: parent_app).reload
        expect(process.organization).to eq(org)
      end

      it 'has a stack from the parent app' do
        stack      = Stack.make
        parent_app = AppModel.make(space:)
        parent_app.lifecycle_data.update(stack: stack.name)
        process = ProcessModel.make

        expect(process.stack).not_to eq(stack)
        process.update(app: parent_app).reload
        expect(process.stack).to eq(stack)
      end

      context 'when an app has multiple ports bound to the same route' do
        subject(:process) { ProcessModelFactory.make(diego: true, ports: [8080, 9090]) }
        let(:route) { Route.make(host: 'host2', space: process.space, path: '/my%20path') }
        let!(:route_mapping1) { RouteMappingModel.make(app: process.app, route: route, app_port: 8080) }
        let!(:route_mapping2) { RouteMappingModel.make(app: process.app, route: route, app_port: 9090) }

        it 'returns a single associated route' do
          expect(process.routes.size).to eq 1
        end
      end

      context 'with sidecars' do
        let(:process) { ProcessModelFactory.make }
        let(:sidecar1)  { SidecarModel.make(app: process.app) }
        let(:sidecar2)  { SidecarModel.make(app: process.app) }
        let(:other_sidecar) { SidecarModel.make(app: process.app) }

        before do
          SidecarProcessTypeModel.make(sidecar: sidecar1, type: process.type)
          SidecarProcessTypeModel.make(sidecar: sidecar2, type: process.type)
          SidecarProcessTypeModel.make(sidecar: other_sidecar, type: 'worker')
        end

        it 'has sidecars' do
          expect(process.reload.sidecars).to contain_exactly(sidecar1, sidecar2)
        end

        context 'when process has less memory than sidecars' do
          let(:process) { ProcessModelFactory.make(memory: 500) }
          let(:sidecar1)  { SidecarModel.make(app: process.app, memory: 400) }

          it 'is invalid' do
            expect { process.update(memory: 300) }.to raise_error Sequel::ValidationFailed
          end
        end
      end
    end

    describe 'Validations' do
      subject(:process) { ProcessModel.new }

      it { is_expected.to validate_presence :app }

      it 'includes validator policies' do
        expect_validator(InstancesPolicy)
        expect_validator(MaxDiskQuotaPolicy)
        expect_validator(MinDiskQuotaPolicy)
        expect_validator(MinLogRateLimitPolicy)
        expect_validator(MinMemoryPolicy)
        expect_validator(AppMaxInstanceMemoryPolicy)
        expect_validator(InstancesPolicy)
        expect_validator(HealthCheckPolicy)
        expect_validator(ReadinessHealthCheckPolicy)
        expect_validator(DockerPolicy)
        expect_validator(ProcessUserPolicy)
      end

      describe 'org and space quota validator policies' do
        subject(:process) { ProcessModelFactory.make(app: parent_app) }
        let(:org) { Organization.make }
        let(:space) { Space.make(organization: org, space_quota_definition: SpaceQuotaDefinition.make(organization: org)) }

        it 'validates org and space using MaxMemoryPolicy' do
          max_memory_policies = process.validation_policies.select { |policy| policy.instance_of? AppMaxMemoryPolicy }
          expect(max_memory_policies.length).to eq(2)
        end

        it 'validates org and space using MaxInstanceMemoryPolicy' do
          max_instance_memory_policies = process.validation_policies.select { |policy| policy.instance_of? AppMaxInstanceMemoryPolicy }
          expect(max_instance_memory_policies.length).to eq(2)
        end

        it 'validates org and space using MaxAppInstancesPolicy' do
          max_app_instances_policy = process.validation_policies.select { |policy| policy.instance_of? MaxAppInstancesPolicy }
          expect(max_app_instances_policy.length).to eq(2)
          targets = max_app_instances_policy.collect(&:quota_definition)
          expect(targets).to contain_exactly(org.quota_definition, space.space_quota_definition)
        end
      end

      describe 'buildpack' do
        subject(:process) { ProcessModel.make }

        it 'allows nil value' do
          process.app.lifecycle_data.update(buildpacks: nil)
          expect do
            process.save
          end.not_to raise_error
          expect(process.buildpack).to eq(AutoDetectionBuildpack.new)
        end

        it 'allows a public url' do
          process.app.lifecycle_data.update(buildpacks: ['git://user@github.com/repo.git'])
          expect do
            process.save
          end.not_to raise_error
          expect(process.buildpack).to eq(CustomBuildpack.new('git://user@github.com/repo.git'))
        end

        it 'allows a public http url' do
          process.app.lifecycle_data.update(buildpacks: ['http://example.com/foo'])
          expect do
            process.save
          end.not_to raise_error
          expect(process.buildpack).to eq(CustomBuildpack.new('http://example.com/foo'))
        end

        it 'allows a buildpack name' do
          admin_buildpack = Buildpack.make
          process.app.lifecycle_data.update(buildpacks: [admin_buildpack.name])
          expect do
            process.save
          end.not_to raise_error

          expect(process.buildpack).to eql(admin_buildpack)
        end

        it 'does not allow a non-url string' do
          process.app.lifecycle_data.buildpacks = ['Hello, world!']
          expect do
            process.save
          end.to raise_error(Sequel::ValidationFailed, /Specified unknown buildpack name: "Hello, world!"/)
        end
      end

      describe 'disk_quota' do
        subject(:process) { ProcessModelFactory.make }

        it 'allows any disk_quota below the maximum' do
          process.disk_quota = 1000
          expect(process).to be_valid
        end

        it 'does not allow a disk_quota above the maximum' do
          process.disk_quota = 3000
          expect(process).not_to be_valid
          expect(process.errors.on(:disk_quota)).to be_present
        end

        it 'does not allow a disk_quota greater than maximum' do
          process.disk_quota = 4096
          expect(process).not_to be_valid
          expect(process.errors.on(:disk_quota)).to be_present
        end
      end

      describe 'log_rate_limit' do
        subject(:process) { ProcessModelFactory.make }

        it 'does not allow a log_rate_limit below the minimum' do
          process.log_rate_limit = -2
          expect(process).not_to be_valid
        end
      end

      describe 'instances' do
        subject(:process) { ProcessModelFactory.make }

        it 'does not allow negative instances' do
          process.instances = -1
          expect(process).not_to be_valid
          expect(process.errors.on(:instances)).to be_present
        end
      end

      describe 'metadata' do
        subject(:process) { ProcessModelFactory.make }

        it 'defaults to an empty hash' do
          expect(ProcessModel.new.metadata).to eql({})
        end

        it 'can be set and retrieved' do
          process.metadata = {}
          expect(process.metadata).to eql({})
        end

        it 'saves direct updates to the metadata' do
          expect(process.metadata).to eq({})
          process.metadata['some_key'] = 'some val'
          expect(process.metadata['some_key']).to eq('some val')
          process.save
          expect(process.metadata['some_key']).to eq('some val')
          process.refresh
          expect(process.metadata['some_key']).to eq('some val')
        end
      end

      describe 'user' do
        subject(:process) { ProcessModelFactory.make(user: process_user) }
        let(:process_user) { 'vcap' }

        before do
          TestConfig.override(additional_allowed_process_users: %w[some_user some_other_user])
        end

        context 'when user is vcap' do
          before do
            TestConfig.override(additional_allowed_process_users: [])
          end

          it 'is always permitted' do
            expect { process.save }.not_to raise_error
          end
        end

        context 'when user is a permitted user' do
          let(:process_user) { 'some_user' }

          it 'does not raise an error' do
            expect { process.save }.not_to raise_error
          end
        end

        context 'when user is nil' do
          let(:process_user) { nil }

          it 'does not raise an error' do
            expect { process.save }.not_to raise_error
          end
        end

        context 'when user is not permitted' do
          let(:process_user) { 'some-random-user' }

          it 'raises an error' do
            expect { process.save }.to raise_error(/user invalid/)
          end
        end
      end

      describe 'quota' do
        subject(:process) { ProcessModelFactory.make }
        let(:log_rate_limit) { 1024 }
        let(:quota) do
          QuotaDefinition.make(memory_limit: 128, log_rate_limit: log_rate_limit)
        end
        let(:space_quota) do
          SpaceQuotaDefinition.make(memory_limit: 128, organization: org, log_rate_limit: log_rate_limit)
        end

        context 'app update' do
          def act_as_cf_admin
            allow(VCAP::CloudController::SecurityContext).to receive_messages(admin?: true)
            yield
          ensure
            allow(VCAP::CloudController::SecurityContext).to receive(:admin?).and_call_original
          end

          let(:org) { Organization.make(quota_definition: quota) }
          let(:space) { Space.make(name: 'hi', organization: org, space_quota_definition: space_quota) }
          let(:parent_app) { AppModel.make(space:) }

          subject!(:process) { ProcessModelFactory.make(app: parent_app, memory: 64, log_rate_limit: 512, instances: 2, state: 'STOPPED') }

          it 'raises error when quota is exceeded' do
            process.memory = 65
            process.state = 'STARTED'
            expect { process.save }.to raise_error(/memory quota_exceeded/)
          end

          it 'raises error when log quota is exceeded' do
            number = (log_rate_limit / 2) + 1
            process.log_rate_limit = number
            process.state = 'STARTED'
            expect { process.save }.to raise_error(/exceeds space log rate quota/)
          end

          context 'when only exceeding the org quota' do
            before do
              org.quota_definition = QuotaDefinition.make(log_rate_limit: 5)
              org.save
            end

            it 'raises an error' do
              process.log_rate_limit = 10
              process.state = 'STARTED'
              expect { process.save }.to raise_error(/exceeds organization log rate quota/)
            end
          end

          it 'does not raise error when log quota is not exceeded' do
            number = (log_rate_limit / 2)
            process.log_rate_limit = number
            process.state = 'STARTED'
            expect { process.save }.not_to raise_error
          end

          it 'raises an error when starting an app with unlimited log rate and a limited quota' do
            process.log_rate_limit = -1
            process.state = 'STARTED'
            expect { process.save }.to raise_error(Sequel::ValidationFailed)
            expect(process.errors.on(:log_rate_limit)).to include("cannot be unlimited in organization '#{org.name}'.")
            expect(process.errors.on(:log_rate_limit)).to include("cannot be unlimited in space '#{space.name}'.")
          end

          it 'does not raise error when quota is not exceeded' do
            process.memory = 63
            process.state = 'STARTED'
            expect { process.save }.not_to raise_error
          end

          it 'can delete an app that somehow has exceeded its memory quota' do
            quota.memory_limit = 32
            quota.save
            process.memory = 100
            process.state = 'STARTED'
            process.save(validate: false)
            expect(process.reload).not_to be_valid
            expect { process.delete }.not_to raise_error
          end

          it 'allows scaling down instances of an app from above quota to below quota' do
            process.update(state: 'STARTED')

            org.quota_definition = QuotaDefinition.make(memory_limit: 72)
            act_as_cf_admin { org.save }

            expect(process.reload).not_to be_valid
            process.instances = 1

            process.save

            expect(process.reload).to be_valid
            expect(process.instances).to eq(1)
          end

          it 'raises error when instance quota is exceeded' do
            quota.app_instance_limit = 4
            quota.memory_limit       = 512
            quota.save

            process.instances = 5
            process.state = 'STARTED'
            expect { process.save }.to raise_error(/instance_limit_exceeded/)
          end

          it 'raises error when space instance quota is exceeded' do
            space_quota.app_instance_limit = 4
            space_quota.memory_limit       = 512
            space_quota.save
            quota.memory_limit = 512
            quota.save

            process.instances = 5
            process.state = 'STARTED'
            expect { process.save }.to raise_error(/instance_limit_exceeded/)
          end

          it 'raises when scaling down number of instances but remaining above quota' do
            process.update(state: 'STARTED')

            org.quota_definition = QuotaDefinition.make(memory_limit: 32)
            act_as_cf_admin { org.save }

            process.reload
            process.instances = 1

            expect { process.save }.to raise_error(Sequel::ValidationFailed, /quota_exceeded/)
            process.reload
            expect(process.instances).to eq(2)
          end

          it 'allows stopping an app that is above quota' do
            process.update(state: 'STARTED')
            org.quota_definition = QuotaDefinition.make(memory_limit: 72)
            act_as_cf_admin { org.save }

            expect(process.reload).to be_started

            process.state = 'STOPPED'
            process.save

            expect(process).to be_stopped
          end

          it 'allows reducing memory from above quota to at/below quota' do
            org.quota_definition = QuotaDefinition.make(memory_limit: 64)
            act_as_cf_admin { org.save }

            process.memory = 40
            process.state = 'STARTED'
            expect { process.save }.to raise_error(Sequel::ValidationFailed, /quota_exceeded/)

            process.memory = 32
            process.save
            expect(process.memory).to eq(32)
          end
        end
      end
    end

    describe 'Serialization' do
      it {
        expect(subject).to export_attributes(
          :enable_ssh,
          :buildpack,
          :command,
          :console,
          :debug,
          :detected_buildpack,
          :detected_buildpack_guid,
          :detected_start_command,
          :diego,
          :disk_quota,
          :docker_image,
          :environment_json,
          :health_check_http_endpoint,
          :health_check_timeout,
          :health_check_type,
          :instances,
          :log_rate_limit,
          :memory,
          :name,
          :package_state,
          :package_updated_at,
          :production,
          :space_guid,
          :stack_guid,
          :staging_failed_reason,
          :staging_failed_description,
          :staging_task_id,
          :state,
          :version,
          :ports
        )
      }

      it {
        expect(subject).to import_attributes(
          :enable_ssh,
          :app_guid,
          :buildpack,
          :command,
          :console,
          :debug,
          :detected_buildpack,
          :diego,
          :disk_quota,
          :docker_image,
          :environment_json,
          :health_check_http_endpoint,
          :health_check_timeout,
          :health_check_type,
          :instances,
          :log_rate_limit,
          :memory,
          :name,
          :production,
          :route_guids,
          :service_binding_guids,
          :space_guid,
          :stack_guid,
          :staging_task_id,
          :state,
          :ports
        )
      }
    end

    describe '#in_suspended_org?' do
      subject(:process) { ProcessModel.make }

      context 'when in a space in a suspended organization' do
        before { process.organization.update(status: 'suspended') }

        it 'is true' do
          expect(process).to be_in_suspended_org
        end
      end

      context 'when in a space in an unsuspended organization' do
        before { process.organization.update(status: 'active') }

        it 'is false' do
          expect(process).not_to be_in_suspended_org
        end
      end
    end

    describe '#stack' do
      it 'gets stack from the parent app' do
        desired_stack = Stack.make
        process = ProcessModel.make

        expect(process.stack).not_to eq(desired_stack)
        process.app.lifecycle_data.update(stack: desired_stack.name)
        expect(process.reload.stack).to eq(desired_stack)
      end

      it 'returns the default stack when the parent app does not have a stack' do
        process = ProcessModel.make

        expect(process.stack).not_to eq(Stack.default)
        process.app.lifecycle_data.update(stack: nil)
        expect(process.reload.stack).to eq(Stack.default)
      end
    end

    describe '#execution_metadata' do
      let(:parent_app) { AppModel.make }

      subject(:process) { ProcessModel.make(app: parent_app) }

      context 'when the app has a droplet' do
        let(:droplet) do
          DropletModel.make(
            app: parent_app,
            execution_metadata: 'some-other-metadata',
            state: VCAP::CloudController::DropletModel::STAGED_STATE
          )
        end

        before do
          parent_app.update(droplet:)
        end

        it "returns that droplet's staging metadata" do
          expect(process.execution_metadata).to eq(droplet.execution_metadata)
        end
      end

      context 'when the app does not have a droplet' do
        it 'returns empty string' do
          expect(process.desired_droplet).to be_nil
          expect(process.execution_metadata).to eq('')
        end
      end
    end

    describe '#run_action_user' do
      subject(:process) { ProcessModelFactory.make }

      context 'when the process belongs to a Docker lifecycle app' do
        subject(:process) { ProcessModelFactory.make({ docker_image: 'example.com/image' }) }
        let(:droplet_execution_metadata) { '{"entrypoint":["/image-entrypoint.sh"],"user":"some-user"}' }

        before do
          process.desired_droplet.update(execution_metadata: droplet_execution_metadata)
          process.desired_droplet.buildpack_lifecycle_data.delete
          process.desired_droplet.reload
        end

        context 'when the process has a user specified' do
          before do
            process.update(user: 'ContainerUser')
          end

          it 'returns the user' do
            expect(process.run_action_user).to eq('ContainerUser')
          end
        end

        context 'when the droplet execution metadata specifies a user' do
          it 'returns the specified user' do
            expect(process.run_action_user).to eq('some-user')
          end
        end

        context 'when the droplet execution metadata DOES NOT specify a user' do
          let(:droplet_execution_metadata) { '{"entrypoint":["/image-entrypoint.sh"]}' }

          it 'defaults the user to root' do
            expect(process.run_action_user).to eq('root')
          end
        end

        context 'when the droplet execution metadata is an empty string' do
          let(:droplet_execution_metadata) { '' }

          it 'defaults the user to root' do
            expect(process.run_action_user).to eq('root')
          end
        end

        context 'when the droplet execution metadata is nil' do
          let(:droplet_execution_metadata) { nil }

          it 'defaults the user to root' do
            expect(process.run_action_user).to eq('root')
          end
        end

        context 'when the droplet execution metadata has invalid json' do
          let(:droplet_execution_metadata) { '{' }

          it 'defaults the user to root' do
            expect(process.run_action_user).to eq('root')
          end
        end

        context 'when the app does not have a droplet assigned' do
          before do
            process.app.update(droplet: nil)
            process.reload
          end

          it 'defaults the user to root' do
            expect(process.run_action_user).to eq('root')
          end
        end
      end

      context 'when the process DOES NOT belong to a Docker lifecycle app' do
        context 'when the process has a user specified' do
          before do
            process.update(user: 'ContainerUser')
          end

          it 'returns the user' do
            expect(process.run_action_user).to eq('ContainerUser')
          end
        end

        context 'when the process DOES NOT have a user specified' do
          it 'returns the default "vcap" user' do
            expect(process.run_action_user).to eq('vcap')
          end
        end
      end
    end

    describe '#specified_or_detected_command' do
      subject(:process) { ProcessModelFactory.make }

      before do
        process.desired_droplet.update(process_types: { web: 'detected-start-command' })
      end

      context 'when the process has a command' do
        before do
          process.update(command: 'user-specified')
        end

        it 'uses the command on the process' do
          expect(process.specified_or_detected_command).to eq('user-specified')
        end
      end

      context 'when the process does not have a command' do
        before do
          process.update(command: nil)
        end

        it 'returns the detected start command' do
          expect(process.specified_or_detected_command).to eq('detected-start-command')
        end
      end
    end

    describe '#detected_start_command' do
      subject(:process) { ProcessModelFactory.make(type:) }
      let(:type) { 'web' }

      context 'when the process has a desired droplet with a web process' do
        before do
          process.desired_droplet.update(process_types: { web: 'run-my-app' })
          process.reload
        end

        it 'returns the web process type command from the droplet' do
          expect(process.detected_start_command).to eq('run-my-app')
        end
      end

      context 'when the process does not have a desired droplet' do
        before do
          process.desired_droplet.app.update(droplet_guid: nil)
          process.desired_droplet.destroy
          process.reload
        end

        it 'returns the empty string' do
          expect(process.desired_droplet).to be_nil
          expect(process.detected_start_command).to eq('')
        end
      end
    end

    describe '#environment_json' do
      let(:parent_app) { AppModel.make(environment_variables: { 'key' => 'value' }) }
      let!(:process) { ProcessModel.make(app: parent_app) }

      it 'returns the parent app environment_variables' do
        expect(process.environment_json).to eq({ 'key' => 'value' })
      end

      context 'when revisions are enabled and we have a revision' do
        let!(:revision) { RevisionModel.make(app: parent_app, environment_variables: { 'key' => 'value2' }) }

        before do
          process.update(revision:)
        end

        it 'returns the environment variables from the revision' do
          expect(process.environment_json).to eq({ 'key' => 'value2' })
        end
      end
    end

    describe '#database_uri' do
      let(:parent_app) { AppModel.make(environment_variables: { 'jesse' => 'awesome' }, space: space) }

      subject(:process) { ProcessModel.make(app: parent_app) }

      context 'when there are database-like services' do
        before do
          sql_service_plan     = ServicePlan.make(service: Service.make(label: 'elephantsql-n/a'))
          sql_service_instance = ManagedServiceInstance.make(space: space, service_plan: sql_service_plan, name: 'elephantsql-vip-uat')
          ServiceBinding.make(app: parent_app, service_instance: sql_service_instance, credentials: { 'uri' => 'mysql://foo.com' })

          banana_service_plan     = ServicePlan.make(service: Service.make(label: 'chiquita-n/a'))
          banana_service_instance = ManagedServiceInstance.make(space: space, service_plan: banana_service_plan, name: 'chiqiuta-yummy')
          ServiceBinding.make(app: parent_app, service_instance: banana_service_instance, credentials: { 'uri' => 'banana://yum.com' })
        end

        it 'returns database uri' do
          expect(process.reload.database_uri).to eq('mysql2://foo.com')
        end
      end

      context 'when there are non-database-like services' do
        before do
          banana_service_plan     = ServicePlan.make(service: Service.make(label: 'chiquita-n/a'))
          banana_service_instance = ManagedServiceInstance.make(space: space, service_plan: banana_service_plan, name: 'chiqiuta-yummy')
          ServiceBinding.make(app: parent_app, service_instance: banana_service_instance, credentials: { 'uri' => 'banana://yum.com' })

          uncredentialed_service_plan     = ServicePlan.make(service: Service.make(label: 'mysterious-n/a'))
          uncredentialed_service_instance = ManagedServiceInstance.make(space: space, service_plan: uncredentialed_service_plan, name: 'mysterious-mystery')
          ServiceBinding.make(app: parent_app, service_instance: uncredentialed_service_instance, credentials: {})
        end

        it 'returns nil' do
          expect(process.reload.database_uri).to be_nil
        end
      end

      context 'when there are no services' do
        it 'returns nil' do
          expect(process.reload.database_uri).to be_nil
        end
      end

      context 'when the service binding credentials is nil' do
        before do
          banana_service_plan     = ServicePlan.make(service: Service.make(label: 'chiquita-n/a'))
          banana_service_instance = ManagedServiceInstance.make(space: space, service_plan: banana_service_plan, name: 'chiqiuta-yummy')
          ServiceBinding.make(app: parent_app, service_instance: banana_service_instance, credentials: nil)
        end

        it 'returns nil' do
          expect(process.reload.database_uri).to be_nil
        end
      end
    end

    describe 'metadata' do
      it 'deserializes the serialized value' do
        process = ProcessModelFactory.make(
          metadata: { 'jesse' => 'super awesome' }
        )
        expect(process.metadata).to eq('jesse' => 'super awesome')
      end
    end

    describe 'command' do
      it 'saves the field as nil when set to nil' do
        process         = ProcessModelFactory.make(command: 'echo hi')
        process.command = nil
        process.save
        process.refresh
        expect(process.command).to be_nil
      end

      it 'does not fall back to metadata value if command is not present' do
        process         = ProcessModelFactory.make(metadata: { command: 'echo hi' })
        process.command = nil
        process.save
        process.refresh
        expect(process.command).to be_nil
      end
    end

    describe 'console' do
      it 'stores the command in the metadata' do
        process = ProcessModelFactory.make(console: true)
        expect(process.metadata).to eq('console' => true)
        process.save
        expect(process.metadata).to eq('console' => true)
        process.refresh
        expect(process.metadata).to eq('console' => true)
      end

      it 'returns true if console was set to true' do
        process = ProcessModelFactory.make(console: true)
        expect(process.console).to be(true)
      end

      it 'returns false if console was set to false' do
        process = ProcessModelFactory.make(console: false)
        expect(process.console).to be(false)
      end

      it 'returns false if console was not set' do
        process = ProcessModelFactory.make
        expect(process.console).to be(false)
      end
    end

    describe 'debug' do
      it 'stores the command in the metadata' do
        process = ProcessModelFactory.make(debug: 'suspend')
        expect(process.metadata).to eq('debug' => 'suspend')
        process.save
        expect(process.metadata).to eq('debug' => 'suspend')
        process.refresh
        expect(process.metadata).to eq('debug' => 'suspend')
      end

      it 'returns nil if debug was explicitly set to nil' do
        process = ProcessModelFactory.make(debug: nil)
        expect(process.debug).to be_nil
      end

      it 'returns nil if debug was not set' do
        process = ProcessModelFactory.make
        expect(process.debug).to be_nil
      end
    end

    describe 'custom_buildpack_url' do
      subject(:process) { ProcessModel.make(app: parent_app) }
      context 'when a custom buildpack is associated with the app' do
        it 'is the custom url' do
          process.app.lifecycle_data.update(buildpacks: ['https://example.com/repo.git'])
          expect(process.custom_buildpack_url).to eq('https://example.com/repo.git')
        end
      end

      context 'when an admin buildpack is associated with the app' do
        it 'is nil' do
          process.app.lifecycle_data.update(buildpacks: [Buildpack.make.name])
          expect(process.custom_buildpack_url).to be_nil
        end
      end

      context 'when no buildpack is associated with the app' do
        it 'is nil' do
          expect(ProcessModel.make.custom_buildpack_url).to be_nil
        end
      end
    end

    describe 'health_check_timeout' do
      before do
        TestConfig.override(maximum_health_check_timeout: 512)
      end

      context 'when the health_check_timeout was not specified' do
        it 'uses nil as health_check_timeout' do
          process = ProcessModelFactory.make
          expect(process.health_check_timeout).to be_nil
        end
      end

      context 'when a valid health_check_timeout is specified' do
        it 'uses that value' do
          process = ProcessModelFactory.make(health_check_timeout: 256)
          expect(process.health_check_timeout).to eq(256)
        end
      end
    end

    describe '#actual_droplet' do
      let(:first_droplet) { DropletModel.make(app: parent_app, state: DropletModel::STAGED_STATE) }
      let(:second_droplet) { DropletModel.make(app: parent_app, state: DropletModel::STAGED_STATE) }
      let(:revision) { RevisionModel.make(app: parent_app, droplet_guid: first_droplet.guid) }
      let(:process) { ProcessModel.make(app: parent_app, revision: revision) }

      before do
        first_droplet
        parent_app.update(droplet_guid: second_droplet.guid)
      end

      context 'when revisions are disabled' do
        let(:parent_app) { AppModel.make(space: space, revisions_enabled: false) }

        it 'returns desired_droplet' do
          expect(process.actual_droplet).to eq(second_droplet)
          expect(process.actual_droplet).to eq(process.latest_droplet)
          expect(process.actual_droplet).to eq(process.desired_droplet)
        end
      end

      context 'when revisions are present and enabled' do
        it 'returns the droplet from the latest revision' do
          expect(process.actual_droplet).to eq(first_droplet)
          expect(process.actual_droplet).to eq(process.revision.droplet)
          expect(process.actual_droplet).not_to eq(process.latest_droplet)
        end
      end
    end

    describe 'staged?' do
      subject(:process) { ProcessModelFactory.make }

      it 'returns true if package_state is STAGED' do
        expect(process.package_state).to eq('STAGED')
        expect(process.staged?).to be true
      end

      it 'returns false if package_state is PENDING' do
        PackageModel.make(app: process.app)
        process.reload

        expect(process.package_state).to eq('PENDING')
        expect(process.staged?).to be false
      end
    end

    describe 'pending?' do
      subject(:process) { ProcessModelFactory.make }

      it 'returns true if package_state is PENDING' do
        PackageModel.make(app: process.app)
        process.reload

        expect(process.package_state).to eq('PENDING')
        expect(process.pending?).to be true
      end

      it 'returns false if package_state is not PENDING' do
        expect(process.package_state).to eq('STAGED')
        expect(process.pending?).to be false
      end
    end

    describe 'staging?' do
      subject(:process) { ProcessModelFactory.make }

      it 'returns true if the latest_build is STAGING' do
        BuildModel.make(app: process.app, package: process.latest_package, state: BuildModel::STAGING_STATE)
        expect(process.reload.staging?).to be true
      end

      it 'returns false if a new package has been uploaded but a droplet has not been created for it' do
        PackageModel.make(app: process.app)
        process.reload
        expect(process.staging?).to be false
      end

      it 'returns false if the latest_droplet is not STAGING' do
        DropletModel.make(app: process.app, package: process.latest_package, state: DropletModel::STAGED_STATE)
        process.reload
        expect(process.staging?).to be false
      end
    end

    describe 'failed?' do
      subject(:process) { ProcessModelFactory.make }

      it 'returns true if the latest_build is FAILED' do
        process.latest_build.update(state: BuildModel::FAILED_STATE)
        process.reload

        expect(process.package_state).to eq('FAILED')
        expect(process.staging_failed?).to be true
      end

      it 'returns false if latest_build is not FAILED' do
        process.latest_build.update(state: BuildModel::STAGED_STATE)
        process.reload

        expect(process.package_state).to eq('STAGED')
        expect(process.staging_failed?).to be false
      end
    end

    describe '#latest_build' do
      let!(:process) { ProcessModel.make app: parent_app }
      let!(:build1) { BuildModel.make(app: parent_app, state: BuildModel::STAGED_STATE) }
      let!(:build2) { BuildModel.make(app: parent_app, state: BuildModel::STAGED_STATE) }

      it 'returns the most recently created build' do
        expect(process.latest_build).to eq build2
      end
    end

    describe '#package_state' do
      let(:parent_app) { AppModel.make }

      subject(:process) { ProcessModel.make(app: parent_app) }

      it 'calculates the package state' do
        expect(process.latest_package).to be_nil
        expect(process.reload.package_state).to eq('PENDING')
      end
    end

    describe 'needs_staging?' do
      subject(:process) { ProcessModelFactory.make }

      context 'when the app is started' do
        before do
          process.update(state: 'STARTED', instances: 1)
        end

        it 'returns false if the latest package has not been uploaded (indicated by blank checksums)' do
          process.latest_package.update(package_hash: nil, sha256_checksum: '')
          expect(process).not_to be_needs_staging
        end

        it 'returns true if PENDING is set' do
          PackageModel.make(app: process.app, package_hash: 'hash')
          expect(process.reload.needs_staging?).to be true
        end

        it 'returns false if STAGING is set' do
          DropletModel.make(app: process.app, package: process.latest_package, state: DropletModel::STAGING_STATE)
          expect(process.needs_staging?).to be false
        end
      end

      context 'when the app is not started' do
        before do
          process.state = 'STOPPED'
        end

        it 'returns false' do
          expect(process).not_to be_needs_staging
        end
      end
    end

    describe 'started?' do
      subject(:process) { ProcessModelFactory.make }

      it 'returns true if app is STARTED' do
        process.state = 'STARTED'
        expect(process.started?).to be true
      end

      it 'returns false if app is STOPPED' do
        process.state = 'STOPPED'
        expect(process.started?).to be false
      end
    end

    describe 'stopped?' do
      subject(:process) { ProcessModelFactory.make }

      it 'returns true if app is STOPPED' do
        process.state = 'STOPPED'
        expect(process.stopped?).to be true
      end

      it 'returns false if app is STARTED' do
        process.state = 'STARTED'
        expect(process.stopped?).to be false
      end
    end

    describe 'web?' do
      context 'when the process type is web' do
        it 'returns true' do
          expect(ProcessModel.make(type: 'web').web?).to be true
        end
      end

      context 'when the process type is NOT web' do
        it 'returns false' do
          expect(ProcessModel.make(type: 'Bieber').web?).to be false
        end
      end
    end

    describe 'version' do
      subject(:process) { ProcessModelFactory.make }

      it 'has a version on create' do
        expect(process.version).not_to be_nil
      end

      it 'updates the version when changing :state' do
        process.state = 'STARTED'
        expect { process.save }.to change(process, :version)
      end

      it 'updates the version on update of :state' do
        expect { process.update(state: 'STARTED') }.to change(process, :version)
      end

      context 'for a started app' do
        before { process.update(state: 'STARTED') }

        context 'when lazily backfilling default port values' do
          before do
            # Need to get the app in a state where diego is true but ports are
            # nil. This would only occur on deployments that existed before we
            # added the default port value.
            default_ports = VCAP::CloudController::ProcessModel::DEFAULT_PORTS
            stub_const('VCAP::CloudController::ProcessModel::DEFAULT_PORTS', nil)
            process.update(diego: true)
            stub_const('VCAP::CloudController::ProcessModel::DEFAULT_PORTS', default_ports)
          end

          context 'when changing fields that do not update the version' do
            it 'does not update the version' do
              process.instances = 3

              expect do
                process.save
                process.reload
              end.not_to(change(process, :version))
            end
          end

          context 'when changing a fields that updates the version' do
            it 'updates the version' do
              process.memory = 17

              expect do
                process.save
                process.reload
              end.to(change(process, :version))
            end
          end

          context 'when the user updates the port' do
            it 'updates the version' do
              process.ports = [1753]

              expect do
                process.save
                process.reload
              end.to(change(process, :version))
            end
          end
        end

        context 'when asked not to update the version' do
          before do
            process.skip_process_version_update = true
          end

          it 'does not update the version for memory' do
            process.memory = 2048
            expect { process.save }.not_to change(process, :version)
          end

          it 'does not update the version for health_check_type' do
            process.health_check_type = 'process'
            expect { process.save }.not_to change(process, :version)
          end

          it 'does not update the version for health_check_http_endpoint' do
            process.health_check_http_endpoint = '/two'
            expect { process.save }.not_to change(process, :version)
          end

          it 'does not update the version for changes to the port' do
            process.ports = [8081]
            expect { process.save }.not_to change(process, :version)
          end

          it 'does not update the version for readiness_health_check_type' do
            process.readiness_health_check_type = 'port'
            expect { process.save }.not_to change(process, :version)
          end

          it 'does not update the version for readiness_health_check_http_endpoint' do
            process.readiness_health_check_http_endpoint = '/two'
            expect { process.save }.not_to change(process, :version)
          end
        end

        it 'updates the version when changing :memory' do
          process.memory = 2048
          expect { process.save }.to change(process, :version)
        end

        it 'updates the version on update of :memory' do
          expect { process.update(memory: 999) }.to change(process, :version)
        end

        it 'does not update the version when changing :instances' do
          process.instances = 8
          expect { process.save }.not_to change(process, :version)
        end

        it 'does not update the version on update of :instances' do
          expect { process.update(instances: 8) }.not_to change(process, :version)
        end

        it 'updates the version when changing :health_check_type' do
          process.health_check_type = 'none'
          expect { process.save }.to change(process, :version)
        end

        it 'updates the version when changing health_check_http_endpoint' do
          process.update(health_check_type: 'http', health_check_http_endpoint: '/oldpath')
          expect do
            process.update(health_check_http_endpoint: '/newpath')
          end.to(change(process, :version))
        end

        it 'updates the version when changing :readiness_health_check_type' do
          process.readiness_health_check_type = 'port'
          expect { process.save }.to change(process, :version)
        end

        it 'updates the version when changing readiness_health_check_http_endpoint' do
          process.update(readiness_health_check_type: 'http', readiness_health_check_http_endpoint: '/oldpath')
          expect do
            process.update(readiness_health_check_http_endpoint: '/newpath')
          end.to(change(process, :version))
        end
      end
    end

    describe '#desired_instances' do
      before do
        @process           = ProcessModel.new
        @process.instances = 10
      end

      context 'when the app is started' do
        before do
          @process.state = 'STARTED'
        end

        it 'is the number of instances specified by the user' do
          expect(@process.desired_instances).to eq(10)
        end
      end

      context 'when the app is not started' do
        before do
          @process.state = 'PENDING'
        end

        it 'is zero' do
          expect(@process.desired_instances).to eq(0)
        end
      end
    end

    describe 'uris' do
      let(:process) { ProcessModelFactory.make(app: parent_app) }

      it 'returns the fqdns and paths on the app' do
        domain = PrivateDomain.make(name: 'mydomain.com', owning_organization: org)
        route  = Route.make(host: 'myhost', domain: domain, space: space, path: '/my%20path')
        RouteMappingModel.make(app: process.app, route: route, process_type: process.type)
        expect(process.uris).to eq(['myhost.mydomain.com/my%20path'])
      end

      it 'eagers load domains' do
        domains = 2.times.map { |i| PrivateDomain.make(name: "domain#{i}.com", owning_organization: org) }
        routes = 4.times.map { |i| Route.make(host: "host#{i}", domain: domains[i % 2], space: space) }
        routes.each { |route| RouteMappingModel.make(app: process.app, route: route, process_type: process.type) }

        uris = nil
        expect do
          uris = process.uris
        end.to have_queried_db_times(/select \* from .domains. where/i, 1)

        expect(uris.length).to eq(4)
      end
    end

    describe 'creation' do
      it 'does not create an AppUsageEvent' do
        expect do
          ProcessModel.make
        end.not_to(change(AppUsageEvent, :count))
      end

      describe 'default_app_memory' do
        before do
          TestConfig.override(default_app_memory: 200)
        end

        it 'uses the provided memory' do
          process = ProcessModel.make(memory: 100)
          expect(process.memory).to eq(100)
        end

        it 'uses the default_app_memory when none is provided' do
          process = ProcessModel.make
          expect(process.memory).to eq(200)
        end
      end

      describe 'default disk_quota' do
        before do
          TestConfig.override(default_app_disk_in_mb: 512)
        end

        it 'uses the provided quota' do
          process = ProcessModel.make(disk_quota: 256)
          expect(process.disk_quota).to eq(256)
        end

        it 'uses the default quota' do
          process = ProcessModel.make
          expect(process.disk_quota).to eq(512)
        end
      end

      describe 'default log_rate_limit' do
        before do
          TestConfig.override(default_app_log_rate_limit_in_bytes_per_second: 1024)
        end

        it 'uses the provided quota' do
          process = ProcessModel.make(log_rate_limit: 256)
          expect(process.log_rate_limit).to eq(256)
        end

        it 'uses the default quota' do
          process = ProcessModel.make
          expect(process.log_rate_limit).to eq(1024)
        end
      end

      describe 'instance_file_descriptor_limit' do
        before do
          TestConfig.override(instance_file_descriptor_limit: 200)
        end

        it 'uses the instance_file_descriptor_limit config variable' do
          process = ProcessModel.make
          expect(process.file_descriptors).to eq(200)
        end
      end

      describe 'default ports' do
        context 'with a diego app' do
          context 'and no ports are specified' do
            it 'does not return a default value' do
              ProcessModel.make(diego: true)
              expect(ProcessModel.last.ports).to be_nil
            end
          end

          context 'and ports are specified' do
            it 'uses the ports provided' do
              ProcessModel.make(diego: true, ports: [9999])
              expect(ProcessModel.last.ports).to eq [9999]
            end
          end
        end
      end
    end

    describe 'saving' do
      it 'calls AppObserver.updated', isolation: :truncation do
        process = ProcessModelFactory.make
        expect(ProcessObserver).to receive(:updated).with(process)
        process.update(instances: process.instances + 1)
      end

      context 'when app state changes from STOPPED to STARTED' do
        it 'creates an AppUsageEvent' do
          process = ProcessModelFactory.make
          expect do
            process.update(state: 'STARTED')
          end.to change(AppUsageEvent, :count).by(1)
          event = AppUsageEvent.last
          expect(event).to match_app(process)
        end
      end

      context 'when app state changes from STARTED to STOPPED' do
        it 'creates an AppUsageEvent' do
          process = ProcessModelFactory.make(state: 'STARTED')
          expect do
            process.update(state: 'STOPPED')
          end.to change(AppUsageEvent, :count).by(1)
          event = AppUsageEvent.last
          expect(event).to match_app(process)
        end
      end

      context 'when app instances changes' do
        it 'creates an AppUsageEvent when the app is STARTED' do
          process = ProcessModelFactory.make(state: 'STARTED')
          expect do
            process.update(instances: 2)
          end.to change(AppUsageEvent, :count).by(1)
          event = AppUsageEvent.last
          expect(event).to match_app(process)
        end

        it 'does not create an AppUsageEvent when the app is STOPPED' do
          process = ProcessModelFactory.make(state: 'STOPPED')
          expect do
            process.update(instances: 2)
          end.not_to(change(AppUsageEvent, :count))
        end
      end

      context 'when app memory changes' do
        it 'creates an AppUsageEvent when the app is STARTED' do
          process = ProcessModelFactory.make(state: 'STARTED')
          expect do
            process.update(memory: 2)
          end.to change(AppUsageEvent, :count).by(1)
          event = AppUsageEvent.last
          expect(event).to match_app(process)
        end

        it 'does not create an AppUsageEvent when the app is STOPPED' do
          process = ProcessModelFactory.make(state: 'STOPPED')
          expect do
            process.update(memory: 2)
          end.not_to(change(AppUsageEvent, :count))
        end
      end

      context 'when a custom buildpack was used for staging' do
        it 'creates an AppUsageEvent that contains the custom buildpack url' do
          process = ProcessModelFactory.make(state: 'STOPPED')
          process.app.lifecycle_data.update(buildpacks: ['https://example.com/repo.git'])
          expect do
            process.update(state: 'STARTED')
          end.to change(AppUsageEvent, :count).by(1)
          event = AppUsageEvent.last
          expect(event.buildpack_name).to eq('https://example.com/repo.git')
          expect(event).to match_app(process)
        end
      end

      context 'when a detected admin buildpack was used for staging' do
        it 'creates an AppUsageEvent that contains the detected buildpack guid' do
          buildpack = Buildpack.make
          process = ProcessModelFactory.make(state: 'STOPPED')
          process.desired_droplet.update(
            buildpack_receipt_buildpack: 'Admin buildpack detect string',
            buildpack_receipt_buildpack_guid: buildpack.guid
          )
          expect do
            process.update(state: 'STARTED')
          end.to change(AppUsageEvent, :count).by(1)
          event = AppUsageEvent.last
          expect(event.buildpack_guid).to eq(buildpack.guid)
          expect(event).to match_app(process)
        end
      end
    end

    describe 'destroy' do
      subject(:process) { ProcessModelFactory.make(app: parent_app) }

      it 'notifies the app observer', isolation: :truncation do
        expect(ProcessObserver).to receive(:deleted).with(process)
        process.destroy
      end

      it 'destroys all dependent crash events' do
        app_event = AppEvent.make(app: process)

        expect do
          process.destroy
        end.to change {
          AppEvent.where(id: app_event.id).count
        }.from(1).to(0)
      end

      it 'creates an AppUsageEvent when the app state is STARTED' do
        process = ProcessModelFactory.make(state: 'STARTED')
        expect do
          process.destroy
        end.to change(AppUsageEvent, :count).by(1)
        expect(AppUsageEvent.last).to match_app(process)
      end

      it 'does not create an AppUsageEvent when the app state is STOPPED' do
        process = ProcessModelFactory.make(state: 'STOPPED')
        expect do
          process.destroy
        end.not_to(change(AppUsageEvent, :count))
      end

      it 'locks the record when destroying' do
        expect(process).to receive(:lock!)
        process.destroy
      end
    end

    describe 'file_descriptors' do
      subject(:process) { ProcessModelFactory.make }
      its(:file_descriptors) { is_expected.to be(16_384) }
    end

    describe 'docker_image' do
      subject(:process) { ProcessModelFactory.make(app: parent_app) }

      it 'does not allow a docker package for a buildpack app' do
        process.app.lifecycle_data.update(buildpacks: [Buildpack.make.name])
        PackageModel.make(:docker, app: process.app)
        expect do
          process.save
        end.to raise_error(Sequel::ValidationFailed, /incompatible with buildpack/)
      end

      it 'retrieves the docker image from the package' do
        PackageModel.make(:docker, app: process.app, docker_image: 'someimage')
        expect(process.reload.docker_image).to eq('someimage')
      end
    end

    describe 'docker_username' do
      subject(:process) { ProcessModelFactory.make(app: parent_app) }

      it 'retrieves the docker registry username from the package' do
        PackageModel.make(:docker, app: process.app, docker_image: 'someimage', docker_username: 'user')
        expect(process.reload.docker_username).to eq('user')
      end
    end

    describe 'docker_password' do
      subject(:process) { ProcessModelFactory.make(app: parent_app) }

      it 'retrieves the docker registry password from the package' do
        PackageModel.make(:docker, app: process.app, docker_image: 'someimage', docker_password: 'pass')
        expect(process.reload.docker_password).to eq('pass')
      end
    end

    describe 'diego' do
      subject(:process) { ProcessModelFactory.make }

      it 'defaults to run on diego' do
        expect(process.diego).to be_truthy
      end

      context 'when updating app ports' do
        subject!(:process) { ProcessModelFactory.make(diego: true, state: 'STARTED') }

        before do
          allow(ProcessObserver).to receive(:updated).with(process)
        end

        it 'calls the app observer with the app', isolation: :truncation do
          expect(ProcessObserver).not_to have_received(:updated).with(process)
          process.ports = [1111, 2222]
          process.save
          expect(ProcessObserver).to have_received(:updated).with(process)
        end

        it 'updates the app version' do
          expect do
            process.ports  = [1111, 2222]
            process.memory = 2048
            process.save
          end.to change(process, :version)
        end
      end
    end

    describe '#needs_package_in_current_state?' do
      it 'returns true if started' do
        process = ProcessModel.new(state: 'STARTED')
        expect(process.needs_package_in_current_state?).to be(true)
      end

      it 'returns false if not started' do
        expect(ProcessModel.new(state: 'STOPPED').needs_package_in_current_state?).to be(false)
      end
    end

    describe '#docker_ports' do
      describe 'when the app is not docker' do
        subject(:process) { ProcessModelFactory.make(diego: true, docker_image: nil) }

        it 'is an empty array' do
          expect(process.docker_ports).to eq []
        end
      end

      context 'when tcp ports are saved in the droplet metadata' do
        subject(:process) do
          process = ProcessModelFactory.make(diego: true, docker_image: 'some-docker-image')
          process.desired_droplet.update(
            execution_metadata: '{"ports":[{"Port":1024, "Protocol":"tcp"}, {"Port":4444, "Protocol":"udp"},{"Port":1025, "Protocol":"tcp"}]}'
          )
          process.reload
        end

        it 'returns an array of the tcp ports' do
          expect(process.docker_ports).to eq([1024, 1025])
        end
      end
    end

    describe 'ports' do
      context 'serialization' do
        it 'serializes and deserializes arrays of integers' do
          process = ProcessModel.make(diego: true, ports: [1025, 1026, 1027, 1028])
          expect(process.ports).to eq([1025, 1026, 1027, 1028])

          process = ProcessModel.make(diego: true, ports: [1024])
          expect(process.ports).to eq([1024])
        end
      end

      context 'docker app' do
        context 'when app is staged' do
          context 'when some tcp ports are exposed' do
            subject(:process) do
              process = ProcessModelFactory.make(diego: true, docker_image: 'some-docker-image', instances: 1)
              process.desired_droplet.update(
                execution_metadata: '{"ports":[{"Port":1024, "Protocol":"tcp"}, {"Port":4444, "Protocol":"udp"},{"Port":1025, "Protocol":"tcp"}]}'
              )
              process.reload
            end

            it 'does not change ports' do
              expect(process.ports).to be_nil
            end

            it 'returns an auto-detect buildpack' do
              expect(process.buildpack).to eq(AutoDetectionBuildpack.new)
            end

            it 'does not save ports to the database' do
              expect(process.ports).to be_nil
            end

            context 'when the user provided ports' do
              before do
                process.ports = [1111]
                process.save
              end

              it 'saves to db and returns the user provided ports' do
                expect(process.ports).to eq([1111])
              end
            end
          end

          context 'when no tcp ports are exposed' do
            it 'returns the ports that were specified during creation' do
              process = ProcessModelFactory.make(diego: true, docker_image: 'some-docker-image', instances: 1)

              process.desired_droplet.update(
                execution_metadata: '{"ports":[{"Port":1024, "Protocol":"udp"}, {"Port":4444, "Protocol":"udp"},{"Port":1025, "Protocol":"udp"}]}'
              )
              process.reload

              expect(process.ports).to be_nil
            end
          end

          context 'when execution metadata is malformed' do
            it 'returns the ports that were specified during creation' do
              process = ProcessModelFactory.make(diego: true, docker_image: 'some-docker-image', instances: 1, ports: [1111])
              process.desired_droplet.update(
                execution_metadata: 'some-invalid-json'
              )
              process.reload

              expect(process.ports).to eq([1111])
            end
          end

          context 'when no ports are specified in the execution metadata' do
            it 'returns the default port' do
              process = ProcessModelFactory.make(diego: true, docker_image: 'some-docker-image', instances: 1)
              process.desired_droplet.update(
                execution_metadata: '{"cmd":"run.sh"}'
              )
              process.reload

              expect(process.ports).to be_nil
            end
          end
        end
      end

      context 'buildpack app' do
        context 'when app is not staged' do
          it 'returns the ports that were specified during creation' do
            process = ProcessModel.make(diego: true, ports: [1025, 1026, 1027, 1028])
            expect(process.ports).to eq([1025, 1026, 1027, 1028])
          end
        end

        context 'when app is staged' do
          context 'with no execution_metadata' do
            it 'returns the ports that were specified during creation' do
              process = ProcessModelFactory.make(diego: true, ports: [1025, 1026, 1027, 1028], instances: 1)
              expect(process.ports).to eq([1025, 1026, 1027, 1028])
            end
          end

          context 'with execution_metadata' do
            it 'returns the ports that were specified during creation' do
              process = ProcessModelFactory.make(diego: true, ports: [1025, 1026, 1027, 1028], instances: 1)
              process.desired_droplet.update(
                execution_metadata: '{"ports":[{"Port":1024, "Protocol":"tcp"}, {"Port":4444, "Protocol":"udp"},{"Port":8080, "Protocol":"tcp"}]}'
              )
              process.reload

              expect(process.ports).to eq([1025, 1026, 1027, 1028])
            end
          end
        end
      end
    end

    describe '#open_ports' do
      let(:parent_app) { AppModel.make }

      context 'when the process is docker' do
        let(:process) { ProcessModel.make(:docker, ports:, type:) }

        subject(:open_ports) { process.open_ports }

        context 'when the process has ports specified' do
          let(:ports) { [1111, 2222] }
          let(:type) { 'worker' }

          context 'when there is at least one route mapping with no port specified' do
            before do
              RouteMappingModel.make(app: process.app, process_type: type, app_port: ProcessModel::NO_APP_PORT_SPECIFIED)
            end

            context 'when the Docker image exposes a port' do
              before do
                allow(process).to receive(:docker_ports).and_return([2222, 3333, 4444])
              end

              it 'uses the port exposed by the Docker image and the process ports' do
                expect(open_ports).to contain_exactly(1111, 2222, 3333, 4444)
              end
            end

            context 'when the Docker image does **not** expose a port' do
              before do
                allow(process).to receive(:docker_ports).and_return(nil)
              end

              it 'uses 8080 and the process ports' do
                expect(open_ports).to contain_exactly(1111, 2222, 8080)
              end
            end
          end

          context 'when all route mappings have ports specified' do
            before do
              RouteMappingModel.make(app: process.app, process_type: type, app_port: 9999)
            end

            it 'uses the process ports' do
              expect(open_ports).to contain_exactly(1111, 2222)
            end
          end
        end

        context 'when the process does not have ports specified, but is a web process' do
          let(:ports) { nil }
          let(:type) { ProcessTypes::WEB }

          context 'when there is at least one route mapping with no port specified' do
            before do
              RouteMappingModel.make(app: process.app, process_type: type, app_port: ProcessModel::NO_APP_PORT_SPECIFIED)
            end

            context 'when the Docker image exposes a port' do
              before do
                allow(process).to receive(:docker_ports).and_return([3333, 4444])
              end

              it 'uses the port exposed by the Docker image' do
                expect(open_ports).to contain_exactly(3333, 4444)
              end
            end

            context 'when the Docker image does **not** expose a port' do
              before do
                allow(process).to receive(:docker_ports).and_return(nil)
              end

              it 'uses 8080' do
                expect(open_ports).to contain_exactly(8080)
              end
            end
          end

          context 'when all route mappings have ports specified' do
            before do
              RouteMappingModel.make(app: process.app, process_type: type, app_port: 9999)
            end

            it 'uses 8080' do
              expect(open_ports).to contain_exactly(8080)
            end
          end
        end

        context 'when the process does not have ports specified, and is not a web process' do
          let(:ports) { nil }
          let(:type) { 'worker' }

          context 'when there is at least one route mapping with no port specified' do
            before do
              RouteMappingModel.make(app: process.app, process_type: type, app_port: ProcessModel::NO_APP_PORT_SPECIFIED)
            end

            context 'when the Docker image exposes a port' do
              before do
                allow(process).to receive(:docker_ports).and_return([3333, 4444])
              end

              it 'uses the port exposed by the Docker image' do
                expect(open_ports).to contain_exactly(3333, 4444)
              end
            end

            context 'when the Docker image does **not** expose a port' do
              before do
                allow(process).to receive(:docker_ports).and_return(nil)
              end

              it 'uses 8080' do
                expect(open_ports).to contain_exactly(8080)
              end
            end
          end

          context 'when all route mappings have ports specified' do
            before do
              RouteMappingModel.make(app: process.app, process_type: type, app_port: 9999)
            end

            it 'does not open any ports' do
              expect(open_ports).to be_empty
            end
          end
        end
      end

      context 'when the process is buildpack' do
        let(:process) { ProcessModel.make(ports:, type:) }

        subject(:open_ports) { process.open_ports }

        context 'when the process has ports specified' do
          let(:ports) { [1111, 2222] }
          let(:type) { 'worker' }

          it 'uses the specified ports' do
            expect(open_ports).to contain_exactly(1111, 2222)
          end
        end

        context 'when the process does not have ports specified, but is a web process' do
          let(:ports) { nil }
          let(:type) { ProcessTypes::WEB }

          it 'uses port 8080' do
            expect(open_ports).to contain_exactly(8080)
          end
        end

        context 'when the process does not have ports specified, and is not a web process' do
          let(:ports) { nil }
          let(:type) { 'worker' }

          it 'does not open any ports' do
            expect(open_ports).to be_empty
          end
        end
      end
    end

    describe 'name' do
      let(:parent_app) { AppModel.make(name: 'parent-app-name') }
      let!(:process) { ProcessModel.make(app: parent_app) }

      it 'returns the parent app name' do
        expect(process.name).to eq('parent-app-name')
      end
    end

    describe 'staging failures' do
      let(:parent_app) { AppModel.make(name: 'parent-app-name') }
      subject(:process) { ProcessModel.make(app: parent_app) }
      let(:error_id) { 'StagingFailed' }
      let(:error_description) { 'stating failed' }

      describe 'when there is a build but no droplet' do
        let!(:build) { BuildModel.make app: parent_app, error_id: error_id, error_description: error_description }

        it 'returns the error_id and error_description from the build' do
          expect(process.staging_failed_reason).to eq(error_id)
          expect(process.staging_failed_description).to eq(error_description)
        end
      end

      describe 'when there is a droplet but no build (legacy case for supporting rolling deploy)' do
        let!(:droplet) { DropletModel.make app: parent_app, error_id: error_id, error_description: error_description }

        it 'returns the error_id and error_description from the build' do
          expect(process.staging_failed_reason).to eq(error_id)
          expect(process.staging_failed_description).to eq(error_description)
        end
      end
    end

    describe 'staging task id' do
      subject(:process) { ProcessModel.make(app: parent_app) }

      context 'when there is a build but no droplet' do
        let!(:build) { BuildModel.make(app: parent_app) }

        it 'is the build guid' do
          expect(process.staging_task_id).to eq(build.guid)
        end
      end

      context 'when there is no build' do
        let!(:droplet) { DropletModel.make(app: parent_app) }

        it 'is the droplet guid if there is no build' do
          expect(process.staging_task_id).to eq(droplet.guid)
        end
      end
    end
  end
end
