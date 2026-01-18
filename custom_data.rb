require_relative "../../factories/rubric_factory"
require_relative "../../factories/rubric_association_factory"
require_relative "../../factories/quiz_factory"
require_relative "../../factories/outcome_factory"
require_relative "../../factories/user_factory"
require_relative "../../factories/pseudonym_factory"
require_relative "../../factories/planner_override_factory"

require_relative "./common"
require_relative "./utils"
require 'json'
require 'yaml'
require 'securerandom'
require 'erb'

# Path from which course data is loaded when needed.
$TEST_DATA_PATH = "/usr/src/app/spec/fixtures/data_generation/odox-6.yaml"
# $TEST_DATA_PATH = "/usr/src/app/spec/fixtures/data_generation/test_data.yaml"
# $TEST_DATA_PATH = "/usr/src/app/spec/fixtures/data_generation/output.yaml"


def generate_test_environment



  puts "Loading test data from container path: #{$TEST_DATA_PATH}"
  

  test_data = YAML.load_file $TEST_DATA_PATH


  output = [] # Holds task instance output data

  courses = [] # Holds the generated course objects

  # Students are shared across all courses.
  students = [] # Hold the student users objects

  test_data['students'].each {|student_data|

      student_data = {
        :name=>student_data["name"],
        :email=>student_data["email"],
        :password=>student_data["password"]
      }

      puts student_data

      puts "Creating student #{student_data[:name]}"

      user_factory(student_data.merge({:active_user=>true}))
      @user.pseudonyms.create!(
        unique_id: student_data[:email],
        password: student_data[:password],
        password_confirmation: student_data[:password]
      )
      @user.email = student_data[:email]
      students << @user

  }  


  test_data["courses"].each {|course| 
    test_course = TestCourse.new({
      :course_name => course["name"],
      :course_code => course["code"],
      :unused_group_names => course["unused_group_names"],
      :unused_announcements => course["unused_announcements"],
      :unused_pages => course["unused_pages"],
      :unused_discussions => course["unused_discussions"],
      :teacher_name => course["instructor"]["name"],
      :teacher_email => course["instructor"]["email"],
      :teacher_password => course["instructor"]["password"],
      :student_name => course["main_user"]["name"],
      :student_email => course["main_user"]["email"],
      :student_password => course["main_user"]["password"]
    })
    courses << test_course
  }


  # Create resources for each course
  courses.each { |_course|
    course_data = test_data["courses"].select {|course| course["name"] == _course.course.name}
    course_data = course_data[0]

    # Enable discussion reply reporting for students. Needed for a task.
    _course.course.root_account.enable_feature! :discussions_reporting
    Account.site_admin.enable_feature!(:menu_option_for_outcome_details_page)
    _course.course.root_account.save!
    Account.site_admin.save!
    

    puts "Is discussion reporting enabled for #{_course.course.name}? #{_course.course.root_account.feature_enabled? :discussions_reporting}"
    puts "Testing"
    puts "Logged in user is #{_course.logged_in_user.name}"

    # As of October 2, 2025: Students should be shared across courses. 
    # Fetch student test data and create enrolled students
    # course_data["students"].each { |student|
    #   puts "Creating student #{student["name"]} in #{_course.course.name}"

    #   _course.create_classmate({
    #     :student_email => student["email"],
    #     :student_name => student["name"],
    #     :student_password => student["password"]
    #   })
    # }

    students.each{|s|
      puts "Enrolling #{s.name} into #{_course.course.name} course."
      _course.enroll_student(s)
    }


    # Fetch quiz test data and create quizzes
    quiz_data = course_data["quizzes"]
    quiz_data.each { |quiz|
      
      puts "Creating quiz #{quiz["title"]} in #{_course.course.name}"

      if quiz["rubric"]
        @quiz = assignment_quiz([], {
          :course=> _course.course,
          :title => quiz["title"],
          :description => quiz["description"],
          :due_at => quiz["due_at"],
          :submission_types => ['online_quiz'],
          :workflow_state => quiz["workflow_state"],
          :user=>_course.logged_in_user
        })

        

        
        # Create the rubric
        puts "Creating rubric #{quiz["rubric"]["title"]} for #{_course.course.name}"

        rubric_opts = quiz["rubric"].merge({
          :user=>_course.teacher,
          :context=>_course.course
        })
        
        rubric = rubric_model(rubric_opts)
        rubric.save!
        rubric.reload

        @assignment.build_rubric_association(
          rubric: rubric,
          purpose: "grading",
          use_for_grading: true,
          context: _course.course
        )
        @assignment.rubric_association.save!

      

        @assignment.reload
        @assignment.save!

                
        # Populate quiz questions
        questions = []
        quiz["questions"].each { |question|
          question[:regrade_option] = false
        }

        quiz["questions"].each { |question_data|
          question = @quiz.quiz_questions.create!(question_data: question_data)
          questions << question
        }
        @quiz.generate_quiz_data
        @quiz.due_at = quiz["due_at"]

        if quiz["one_question_at_a_time"]
          @quiz.one_question_at_a_time = true
          @quiz.save!
        end

        if quiz["allowed_attempts"]
          @quiz.allowed_attempts = quiz["allowed_attempts"]
          @quiz.save!
        end

        @quiz.save!
        @quiz.publish!

        _course.quizzes << @quiz

        if quiz["submissions"]

        quiz["submissions"].each{|submission|

          puts "Processing quiz submission data for user #{submission['user']}"
          student = _course.resolve_user_value(submission["user"], _course)

          submission["attempts"].each_with_index{ |attempt, index|

            puts "Before quiz submission generation"
            puts "Generating #{@quiz.title} quiz submission for student #{student.name}"
            qsub = @quiz.generate_submission(student)
            puts "After quiz submission generation"
            qsub.started_at = 1.minute.ago
            qsub.attempt = index + 1
            qsub.update_attribute(:attempt, index + 1)

            attempt["answers"] = attempt["answers"].map.with_index{|answer, index| 
              answer.transform_keys(&:to_sym)
              # NOTE: only use quizzes with multiple choice questions for this nonsense. 
              # make sure the ids for questions and aswers are valid by pulling them from the quiz rather than the test data
              answer[:question_id] = @quiz.quiz_questions[index].id
              answer[:answer_id] = @quiz.quiz_questions[index].question_data["answers"].sample["id"] # pick a random answer
              answer[:text] = answer[:answer_id].to_s
              answer
            }

            puts "Answers: #{attempt["answers"]}"

            attempt["answers"] = attempt["answers"].map{|answer| answer.symbolize_keys}

            puts "Answers: #{attempt["answers"]}"

            # Get the real question id from the actual quiz itself instead of relying on the static test data
            if attempt["partial"]
              # Get the question answer from the static data
              question_answer_key = attempt["partial"].keys.select{|k| (k.include? 'question_') && (!k.include? 'marked')}.first
              puts "Question Answer Key: #{question_answer_key}"
              question_answer = attempt["partial"][question_answer_key]
              puts "Question Answer: #{question_answer}"

              # Remove the static keys
              attempt["partial"].delete(question_answer_key)
              attempt["partial"].delete(question_answer_key + "_marked")

              # Find the real question id
              question_id = @quiz.quiz_questions[0].id

              # Find the real answer id
              answer_id = @quiz.quiz_questions[0].question_data["answers"].sample["id"]
              question_answer = answer_id.to_s

              # Re-insert the appropriate keys into the partial hash. 
              attempt["partial"]["question_" + question_id.to_s] = question_answer
              attempt["partial"]["question_" + question_id.to_s + "_marked"] = false

              # Symbolize, it won't work otherwise.
              attempt["partial"] = attempt["partial"].symbolize_keys
              
              puts "Partial data: #{attempt["partial"]}"
            end
            # qsub.record_answer(attempt["answers"][0])
            qsub.submission_data = attempt["workflow_state"] == 'untaken'? attempt["partial"] : attempt["answers"]
           
            qsub.score = attempt["workflow_state"] == 'untaken'? nil : 0
            qsub.finished_at = attempt["workflow_state"] == 'untaken'? nil:Time.now.utc
            qsub.workflow_state = attempt["workflow_state"]

            # qsub.submission = @quiz.assignment.find_or_create_submission(student.id)
            # qsub.submission.quiz_submission = qsub
            qsub.submission.submission_type = "online_quiz"
            qsub.submission.submitted_at = qsub.finished_at

            

            if attempt["feedback"]

              grader = _course.resolve_user_value(attempt["feedback"]["grader"], _course)

              if attempt["feedback"]["comment"]
                qsub.submission.add_comment(comment: attempt["feedback"]["comment"], author: grader)
              end

            end

            qsub.save!

          }



        }

      end

      else

        quiz_opts = quiz.except("rubric", "questions")

        q = _course.course.quizzes.create!(quiz_opts) # Create the actual quiz

        if quiz["one_question_at_a_time"]
          puts "ONE QUESTION AT A TIME!"
          q.one_question_at_a_time = true
          q.save!
        end

        if quiz["allowed_attempts"]
          q.allowed_attempts = quiz["allowed_attempts"]
          q.save!
        end

        
        # Populate quiz questions
        questions = []
        
        quiz["questions"].each { |question|
          question[:regrade_option] = false
        }

        quiz["questions"].each { |question_data|
          question = q.quiz_questions.create!(question_data: question_data)
          questions << question
        }
        
        q.generate_quiz_data

        q.save!
        q.publish!

        _course.quizzes << q
      end
      


      }


   
    # Fetch group category test data and create these in anticipation of creating groups
    if course_data["group_categories"]
      course_data["group_categories"].each {|group_category|
        _course.create_group_category(group_category)
      }
    end


    # Fetch group test data and create student groups
    course_data["groups"].each { |group|
      puts "Creating group '#{group["name"]}' in #{_course.course.name}"
       _course.create_group(group)
    }

    # Fetch page test data and create pages for the course
    course_data["pages"].each {|page|
      _course.create_page(page)
    }

    # Fetch discussion test data and create discussions for the course.
    course_data["discussions"].each { |discussion|
      puts "Creating discussion '#{discussion["title"]}' in  #{_course.course.name}"
      _course.create_discussion(discussion)
    }

    # Fetch announcement test data and create announcements
    course_data["announcements"].each {|announcement|

      puts "Creating announcement '#{announcement["title"]}' in #{_course.course.name}"

      _course.create_announcement(announcement)

      override = planner_override_model(user: _course.logged_in_user, plannable: @announcement, marked_complete: true, dismissed: true)
      override.reload
      override.save!

      # override = @announcement.planner_overrides.create!(user: _course.logged_in_user)
      # override.dismissed = true
      # override.save!

    }

    # Fetch assignment test data and create assignments
    course_data["assignments"].each { |assignment|
      puts "Creating assignment #{assignment["title"]} in #{_course.course.name}"

      if assignment["submission_types"].include?("discussion_topic")
        _course.create_discussion_assignment(assignment)
        next
      end

      assignment_opts = _course.default_assignment_opts
      assignment_opts[:title] = assignment["title"]
      assignment_opts[:description] = assignment["description"]
      assignment_opts[:due_at] = assignment["due_at"]
      assignment_opts[:points_possible] = assignment["points_possible"]
      assignment_opts[:created_at] = assignment["created_at"]
      assignment_opts[:updated_at] = assignment["updated_at"]
      # Submission types should be a simple comma delimited string, eg: online_text_entry,online_url
      assignment_opts[:submission_types] = assignment["submission_types"].join(",")

      a = _course.create_assignment(assignment_opts)

      # Create a dummy rubric for the assignment
      rubric_opts = {
        :context => _course.course,
        :title => "Rubric for #{assignment["title"]}",
        :data => _course.make_rubric(assignment["points_possible"])
      }
      rubric = rubric_model(rubric_opts)
      rubric.save!
      rubric.reload

      a.build_rubric_association(
        rubric: rubric,
        purpose: "grading",
        use_for_grading: true,
        context: _course.course
      )
      a.rubric_association.save!

      # # Planner override
      # override = a.planner_overrides.create!(user: _course.logged_in_user)
      # override.update_attribute(:dismissed, true)
      # override.reload
      # override.save!

      a.reload
      a.save!



      # Populate assignment submissions
      if assignment["submissions"] # If the assignment has submissions, create those too.
        assignment["submissions"].each { |submission|
          submission["user"] = _course.resolve_user_value(submission["user"], _course)
          _submission = a.submit_homework(submission["user"], submission.except("user"))

          if submission["peer_review"] # If there are peer review or instructor feedback comments create those too!
            submission["peer_review"].each { |review|
              review["author"] = _course.resolve_user_value(review["author"], _course)
              _submission.add_comment(comment: review["comment"], author: review["author"])
              
              if review["rubric_assessment"] # If rubric feedback was included.
                

                assessment = a.rubric_association.rubric_assessments.build(
                  user: _course.resolve_user_value(submission["user"], _course),
                  assessor: _course.resolve_user_value(review["author"], _course),
                  artifact: _submission,
                  rubric: a.rubric_association.rubric,
                  assessment_type: 'peer_review'
                  #assessment: review["rubric_assessment"].merge(assessment_type: 'peer_review')
                )
                assessment.data = review["rubric_assessment"]
                assessment.score = review["rubric_assessment"].sum {|h| h["points"]}

                puts "Assessment data: #{assessment.data}"

                assessment.save!
                
              end
            
            }
          end

          _submission.save!

          # If there is instructor feedback for the submission let's create it now.
          if submission["feedback"]
            feedback = submission["feedback"]
            
            # Resolve the grader string from the test data to an actual user account
            feedback["grader"] = _course.resolve_user_value(feedback["grader"], _course)
            
            if feedback["grade"] # If a grade is specified, assign that grade to the submission  
              a.grade_student(submission["user"], grade: feedback["grade"], grader: feedback["grader"])
            end
            
            if feedback["comment"] # If there is a feedback comment add it to the submission
              _submission.add_comment(comment: feedback["comment"], author: feedback["grader"])
            end

            if feedback["rubric_assessment"] # If rubric feedback was included.
                

                assessment = a.rubric_association.rubric_assessments.build(
                  user: _course.resolve_user_value(submission["user"], _course),
                  assessor: _course.resolve_user_value(feedback["grader"], _course),
                  artifact: _submission,
                  rubric: a.rubric_association.rubric,
                  assessment_type: 'grading'
                )
                assessment.data = feedback["rubric_assessment"]
                assessment.score = feedback["rubric_assessment"].sum {|h| h["points"]}

                puts "Assessment data: #{assessment.data}"

                assessment.save!
                
              end

          end
        }
      end

      if assignment["peer_reviews"] # If the assignment has peer reviews enabled, set those up.
        a.peer_review_count = assignment["peer_reviews"]["count"]
        a.automatic_peer_reviews = assignment["peer_reviews"]["automatic_peer_reviews"]
        a.update!(peer_reviews: true)
        a.save!
        result = a.assign_peer_reviews

        # Create assessment requests
        a.submissions.each{|submission|
          # Don't make the logged in user peer review their own submission.
          if (submission.user != _course.logged_in_user) && (!submission.unsubmitted?)
            assessment_request = AssessmentRequest.create!(
              asset: submission,
              user: submission.user,
              assessor: _course.logged_in_user,
              assessor_asset: a.submission_for_student(_course.logged_in_user)
            )
            puts "Created peer review request for #{submission.user.name}'s assignment submission."
          end
        

        }        

      end

    }


    _course.course.conditional_release = true
    _course.course.save!


    # Fetch module test data and create the appropriate modules
    course_data["modules"].each{ |mod|

      _course.create_module(mod)

    }

    # Fetch and create course outcomes 
    outcome_data = course_data["outcomes"]

    outcome_data.each{|outcome_name|
      @outcome = _course.course.created_learning_outcomes.build(
        title: outcome_name,
        description: 'A learning outcome'
      )

      outcome_with_rubric({
          :course => _course.course,
          :outcome => @outcome
          })
      # _course.course.root_outcome_group.add_outcome(@outcome)
      # _course.course.root_outcome_group.save!
      _course.course.reload

      puts "Created #{@outcome.title} outcome for #{_course.course.name}" 

      _course.assignments.each{|assignment|
    
          allignment = @outcome.align(assignment, _course.course)
          puts "Aligned #{assignment.title} to #{@outcome.title} outcome in #{_course.course.name}"
          
          if !assignment.rubric_association.nil?
            
            # Find rubric assessment for this student
            assessment = assignment.rubric_association.rubric_assessments.select {|assessment| assessment.user == _course.logged_in_user}.first
            
            if !assessment.nil?

              create_learning_outcome_result(_course.logged_in_user, 5, assignment, allignment, assignment.rubric_association, assessment, Time.zone.now  )
              puts "Created Learning Outcome result for #{_course.logged_in_user.name} for #{assignment.title} in #{_course.course.name}"
            end

          end

        }
    }




  }

  courses

end

def create_learning_outcome_result(user, score, assignment, alignment, rubric_association, rubric_assessment, submitted_at)
    title = "#{user.name}, #{assignment.name}"
    possible = @outcome.points_possible
    mastery = (score || 0) >= @outcome.mastery_points

    LearningOutcomeResult.create!(
      learning_outcome: @outcome,
      user:,
      context: @course,
      alignment:,
      associated_asset: assignment,
      association_type: "RubricAssociation",
      association_id: rubric_association.id,
      artifact_type: 'RubricAssessment',
      artifact_id: rubric_assessment.id,
      title:,
      score:,
      possible:,
      mastery:,
      created_at: submitted_at,
      updated_at: submitted_at,
      submitted_at:,
      assessed_at: submitted_at
    )
  end

# Combine a list of task objects together into an aggregate, where all task instances are organized under their respective tasks.
def aggregate_task_objects(tasks)

  puts "Aggregating #{tasks.length} tasks into instances."
  result = []

  tasks.each { |task|
    task_entry = result.select {|item| item[:id] == task[:id]}[0]

    if task_entry.nil?
      task_entry = {}
      task_entry[:id] = task[:id]
      task_entry[:type] = task[:type]
      
      if task[:answer_type]
        task_entry[:answer_type] = task[:answer_type]
      end

      task_entry[:parameterized_text] = task[:parameterized_text]
      task_entry[:parameters] = task[:parameters]
      task_entry[:instances] = []
      
      result << task_entry

    end

    instance_data = {}
    instance_data[:id] = SecureRandom.uuid
    instance_data[:instance_text] = task[:instance_text]
    instance_data[:instance_username] = task[:instance_username]
    instance_data[:instance_password] = task[:instance_password]
    instance_data[:mapping] = task[:mapping]

    if task[:answer_key]
      instance_data[:answer_key] = task[:answer_key]
    end

    task_entry[:instances] << instance_data

  }

  result

end

def create_task_instances(test_course)

  resource_manifest = ResourceManifest.new(test_course)

  tasks = []

  task = AgentTask.new({
    id: "9b30427c-2025-48db-baed-2cff271cd819",
    evaluation_parameters: ["Group 1 ID", "Group 2 ID"],
    methods: ["POST","POST"],
    paths: ["/api/v1/groups/[[Group 1 ID]]/memberships/self", "/api/v1/groups/[[Group 2 ID]]/memberships"],
    request_kvs: [{
      "_method": "DELETE"
      },{
      "_method": "POST"
      }],
    parameterized_text: "Task: In the course '[[Course]]' switch from your current group '[[Group 1]]' to the group '[[Group 2]]' within the 'Student Groups' group set."
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
        'group',
        test_course.groups,
        lambda {|groups| groups.select{|g| (g.users.include? test_course.logged_in_user) }},
        task))

  resource_manifest.add_resource_request(ResourceRequest.new(
      'group',
      test_course.groups,
      lambda {|groups| groups.select{ |g| (!g.users.include? test_course.logged_in_user) }},
      task
  ))

  task.populate(test_course) { |course, task|

      

      # find a group that the logged-in user is part of.
      group1 = course.groups.select {|group| (group.users.include? course.logged_in_user) && (!AgentTask.groups.include? group)}.first

      if group1.nil?
        puts "Cannot find group containing the logged in user for task #{task.id}"
        return
      end

      # find a group that the logged-in user in not a part of. 
      group2 = course.groups.select {|group| (!group.users.include? course.logged_in_user) && (!AgentTask.groups.include? group) }.first

      if group2.nil?
        puts "Cannot find group that does not contain the logged in user for task #{task.id}"
        return
      end

      # Register these groups as being used.
      AgentTask.groups << group1 
      AgentTask.groups << group2


      # Generate task instance text
      task.update_initalized_text("Course", course.course.name)
      task.update_initalized_text("Group 1", group1.name)
      task.update_initalized_text("Group 2", group2.name)

      task.update_answer_key("Group 1 ID", group1.id)
      task.update_answer_key("Group 2 ID", group2.id)

  }

  tasks << task

  task = AgentTask.new({
    id: "0b925826-6333-43cf-9eb0-4b5cb49a7e7d",
    type: 'Information Seeking',
    answer_type: 'Date Time',
    parameterized_text: 'Task: In the course "[[Course]]" use the Syllabus page to find the due date for the assignment titled "[[Assignment]]".'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda {|assignments| assignments.select{true}},
    task
  ))

  task.populate(test_course) { |course,task|

    assignment = course.assignments.select {|a| (!AgentTask.assignments.include? a)}.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    # Register this assignment as being used.
    AgentTask.assignments << assignment

    task.instance_variable_set(:@assignment, assignment)

    # Generate task instance text
    task.update_initalized_text("Course", course.course.name )
    task.update_initalized_text("Assignment", assignment.title)

    task.answer_key = {
      "Date Time": assignment.due_at.strftime("%Y-%m-%d %H:%M")
    }

  }

  tasks << task

  task = AgentTask.new({
    id: "0be01f7a-0c6e-49c3-af20-52f9b97ef728",
    evaluation_parameters: ["Course ID", "Assignment ID", "User ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[User ID]]"],
    request_kvs: [{
      "_type": "form data",
      "submission[comment]": ["Thank you for the feedback!"]
    }],
    parameterized_text: "Task: View the feedback left by your instructor for the assignment '[[Assignment]]' in the course '[[Course]]', and add a comment saying 'Thank you for the feedback!' using the Feedback sidebar."
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{ |a|
       submission = a.submissions.find_by(user_id: test_course.logged_in_user.id)
       comment_by_teacher = submission.submission_comments.select {|comment| comment.author == test_course.teacher}.first
       comment_by_teacher
    }},
    task
  ))

  task.populate(test_course) { |course,task|

    assignment = course.assignments.select {|a| # Find an assignment
      # that has a submission by the logged in user.
      submission = a.submissions.find_by(user_id: course.logged_in_user.id)
      # where that submission has a comment provided by the course instructor. 
      comment_by_teacher = submission.submission_comments.select {|comment| comment.author == course.teacher}.first
      comment_by_teacher
  }.first

    if (assignment.nil?) || (AgentTask.assignments.include? assignment)
      puts "Could not find assignment with submission and instructor feedback for task #{task.id}"
      return 
    end

    # Register this assignment as being used.
    AgentTask.assignments << assignment

    # Get the assignment subission with feedback
    submission = assignment.submissions.find_by(user_id: course.logged_in_user.id)

    # Generate task instance text
    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", assignment.id)
    task.update_answer_key("User ID", course.logged_in_user.id)

  }

  tasks << task

  task = AgentTask.new({
    id: "117ad520-4107-4488-9101-a2a951daebdf",
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: View the rubric for the quiz titled "[[Quiz]]" in the course "[[Course]]" by navigating to the Grades page, clicking on "[[Quiz]]" and then clicking the "Show Rubric" link on the submission details page. What is the sum total number of points possible across all criteria on the rubric?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes, 
    lambda{|quizzes| quizzes.select{|q| (!q.assignment.nil?) && (!q.assignment.rubric_association.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task| 

    # Look for an unused quiz with a rubric
    quiz = course.quizzes.select{ |q| (!AgentTask.quizzes.include? q ) && (!q.assignment.nil?) && (!q.assignment.rubric_association.nil?)}.first 

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    #Register this assignment as being used.
    AgentTask.quizzes << quiz
    task.instance_variable_set(:@quiz, quiz)

    # Generate task instance text
    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)
  
    total_points = quiz.assignment.rubric_association.rubric.data.sum{|i| i[:points]}

    task.answer_key = {
      "Number": total_points
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '14875b88-4d4f-44be-a989-cff2a705958e',
    type: 'Side-effect',
    evaluation_parameters: ["Course ID", "User 1 ID", "User 2 ID"],
    methods: ['POST'],
    paths: ["/courses/[[Course ID]]/groups"],
    request_kvs: [{
      "join_level": "invitation_only",
      "invitees": ["[[User 1 ID]]", "[[User 2 ID]]"]
      }],
    parameterized_text: 'Task: Create a new student group named "[[Group]]" in the course "[[Course]]", set the group membership to "Membership by invitation only", and invite students named "[[User 1]]" and "[[User 2]]" to join the group.'
  })


  task.populate(test_course) {|course,task| 


    group_name = course.unused_group_names.select {|name| !AgentTask.used_group_names.include? name}.first

    AgentTask.used_group_names << group_name

    user_1 = course.classmates.select {|classmate| (!AgentTask.users.include? classmate)}.first

    AgentTask.users << user_1

    user_2 = course.classmates.select {|classmate| (!AgentTask.users.include? classmate)}.first

    if user_2.nil?
      # Ideally this would be an unused user but it doesn't matter too much for this task. 
      user_2 = course.classmates.select { |classmate| classmate != user_1}.first
    end

    AgentTask.users << user_2


    # Set up the task instance text.
    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group_name)
    task.update_initalized_text("User 1", user_1.name)
    task.update_initalized_text("User 2", user_2.name)

    # Compile answer key for evaluation. 
    # For side effect tasks this will be an array of 
    # objects (method, path, request_kv)
    # The key-value pairs in the request_kv object must be found in the corresponding network event log.
    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("User 1 ID", user_1.id)
    task.update_answer_key("User 2 ID", user_2.id)

  }

  tasks << task

  task = AgentTask.new({
    id: "0b62c5d4-a6fe-4083-9123-45e3087c1440",
    type: 'Side-effect',
    evaluation_parameters: ["Group ID", "Announcement Message","Announcement Title"],
    paths: ["/api/v1/groups/[[Group ID]]/discussion_topics"],
    methods: ["POST"],
    request_kvs: [
      {
      "message": "<p>[[Announcement Message]]</p>",
      "title": "[[Announcement Title]]"
      }],
    parameterized_text: 'Task: In your group "[[Group]]" for the course [[Course]], create a new announcement with the title "[[Announcement]]" and the following content: "[[Announcement Message]]" then publish it.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g|(g.users.include? test_course.logged_in_user) }},
    task
  ))

  task.populate(test_course) { |course, task|

    # pick a group which hasn't been used for a task before and to which the logged in user belongs.
    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user) }.first 

    if group.nil?
      puts "Could not find group for task #{task.id} in course: #{course.course.name}"
      return
    end

    announcement_data = course.unused_announcements.select{|a| !AgentTask.used_announcements.include? a}.first

    AgentTask.used_announcements << announcement_data

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Announcement", announcement_data["title"])
    task.update_initalized_text("Announcement Message", announcement_data["message"])

    task.update_answer_key("Announcement Message", announcement_data["message"])
    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Announcement Title", announcement_data["title"])

  }

  tasks << task

  task = AgentTask.new({
    id: "14fe049e-9db4-497a-97c9-507a2c60d55e",
    type: 'Side-effect',
    answer_ids: [1, 2], # There are two known ways to successfully complete this task. Fullfilling either network request is sufficient.
    evaluation_parameters: ["Course ID", "Discussion ID"],
    methods: ["POST", "PUT"],
    paths: ["/api/graphql", "/api/v1/courses/[[Course ID]]/discussion_topics/[[Discussion ID]]/subscribed"],
    request_kvs: [{
      "operationName": "subscribeToDiscussionTopic",
      "discussionTopicId": "[[Discussion ID]]"
    }, {}],
    parameterized_text: 'Task: Subscribe to the "[[Discussion]]" discussion in the "[[Course]]" course so that you receive notifications when new comments are posted.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda {|discussions| discussions.select{true}},
    task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| !AgentTask.discussions.include? d}.first

    # Ensure the logged in user is NOT subscribed to this discussion topic so that the task makes sense.
    discussion.unsubscribe(course.logged_in_user)
    
    if discussion.nil? 
      puts "Could not find discussion for task #{task.id}"
      return
    end
    
    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)

    task.update_answer_key("Discussion ID", discussion.id)
    task.update_answer_key("Course ID", course.course.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '158b7ece-5c61-466f-9447-9ab9e43c0b03',
    type: 'Side-effect',
    evaluation_parameters: ["Course ID", "Quiz ID", "3rd Question ID"],
    methods: ["POST","POST","POST"],
    paths: [
      "/courses/[[Course ID]]/quizzes/[[Quiz ID]]/take",
      "/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions/backup",
      "/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions"
    ],
    request_kvs: [{},
        {
        "question_[[3rd Question ID]]_marked": ["1"]
        },
        {}],
    parameterized_text: 'Task: Take the "[[Quiz]]" quiz in the "[[Course]]" course, answer all questions, flag question 3 for review, and submit the quiz when finished.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda{|quizzes| quizzes.select{|q| q.quiz_questions.length >= 3}},
    task
  ))
  
  task.populate(test_course) { |course, task|

    # Find a quiz with at least 3 questions
    quiz = course.quizzes.select{|q| (!AgentTask.quizzes.include? q) && q.quiz_questions.length >= 3}.first

    if quiz.nil? 
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Quiz ID", quiz.id)
    task.update_answer_key("3rd Question ID", quiz.quiz_questions[2].id)

  }

  tasks << task

  task = AgentTask.new({
    id: '175397c6-1439-40ab-8b74-8f0e479ef8c5',
    evaluation_parameters: ["Course ID", "Quiz ID", "Question Index", "Answer"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions/backup"],
    request_kvs: [{
      "question_[[Question Index]]": ["[[Answer]]"]
      }],
    parameterized_text: 'Task: In the course "[[Course]]" open the quiz titled "[[Quiz]]" and answer Question [[Question Index]], which is a short answer question, by typing "[[Answer]]" into the provided text box.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda{|quizzes| 
      # Fetch quiz directly from test data to identify correct answer easily.
      test_data = YAML.load_file $TEST_DATA_PATH
      course_data = test_data["courses"].select{|c|c["name"] == test_course.course.name}.first

      # Create a list of used quiz names to ensure we're not re-using a quiz used by a different task.
      used_quiz_names = []
      AgentTask.quizzes.each {|q| used_quiz_names << q.title}

      quiz = course_data["quizzes"].select {|q| (!used_quiz_names.include? q["title"]) && (q["questions"].length >= 2) && (!q["questions"].select{|question| question["question_type"] == "short_answer_question"}.first.nil?) && (!q["one_question_at_a_time"])}.first

      quizzes.select{|q| q.title == quiz["title"]}

    },
    task
  ))

  task.populate(test_course) {|course, task|

    # Fetch quiz directly from test data to identify correct answer easily.
    test_data = YAML.load_file $TEST_DATA_PATH
    course_data = test_data["courses"].select{|c|c["name"] == course.course.name}.first

    # Create a list of used quiz names to ensure we're not re-using a quiz used by a different task.
    used_quiz_names = []
    AgentTask.quizzes.each {|q| used_quiz_names << q.title}

    quiz = course_data["quizzes"].select {|q| (!used_quiz_names.include? q["title"]) && (q["questions"].length >= 2) && (!q["questions"].select{|question| question["question_type"] == "short_answer_question"}.first.nil?) && (!q["one_question_at_a_time"])}.first

    if quiz.nil?
      puts "Could not find quiz for task #{task.id}"
      return
    end

    # Find a short answer question in the quiz
    question = quiz["questions"].select{|question| question["question_type"] == "short_answer_question"}.first
    question_index = quiz["questions"].find_index(question)
    answer = question["answers"].select{|a| a["weight"] == 100}.first

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz["title"])
    task.update_initalized_text("Question Index", (question_index + 1).to_s)
    task.update_initalized_text("Answer", answer["text"])


    _quiz = course.quizzes.select{|q| q.title == quiz["title"]}.first
    AgentTask.quizzes << _quiz # register the quiz as being used. 

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Quiz ID", _quiz.id)
    task.update_answer_key("Question Index", _quiz.quiz_questions[question_index].id) # TODO: I think this is correct, but verify.
    task.update_answer_key("Answer", answer["text"])


  }

  tasks << task

  task = AgentTask.new({
    id: '1977dbaa-1d14-4b08-a40b-0090df524371',
    evaluation_parameters: ["Group ID","Discussion ID"],
    methods: ["PUT"],
    paths: ["/api/v1/groups/[[Group ID]]/discussion_topics/[[Discussion ID]]"],
    request_kvs: [{"locked": true}],
    parameterized_text: 'Task:  In your group ([[Group]]) for the course "[[Course]]" close your own discussion titled "[[Discussion]]" for comments.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| groups.select{|g| (g.users.include? test_course.logged_in_user) && (!g.discussion_topics.select {|dt| (dt.user == test_course.logged_in_user) && (!dt.is_announcement)}.first.nil?) }},
    task
  ))

  task.populate(test_course){|course,task|

    group = course.groups.select {|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user) && (!g.discussion_topics.select {|dt| (dt.user == test_course.logged_in_user) && (!dt.is_announcement)}.first.nil?) }.first

    if group.nil?
      puts "Cannot find group for task #{task.id} in #{course.course.name}"
      return 
    end

    AgentTask.groups << group

    discussion_topic = group.discussion_topics.select{|dt| (dt.user == course.logged_in_user) && (!dt.is_announcement) }.first
    
    if discussion_topic.nil?
      puts "Cannot find discussion topic for task #{task.id}"
      return
    end

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Discussion", discussion_topic.title)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Discussion ID", discussion_topic.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '19816faf-81ee-4235-8228-eb3d45e6bad3',
    type: 'Information Seeking',
    answer_type: 'Date Time',
    parameterized_text: 'Task: View the details of the "[[Assignment]]" assignment in the "[[Course]]" course, and return its due date.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{true}},
    task
  ))

  task.populate(test_course){ |course, task|

    assignment = course.assignments.select {|a| (!AgentTask.assignments.include? a)}.first

    if assignment.nil?
      puts "Could not find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.answer_key = {
      "Date Time": assignment.due_at.strftime("%Y-%m-%d %H:%M")
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '2b0a143f-fb9c-4f8e-9606-211e6bcb8171',
    evaluation_parameters: ["Course ID", "User ID"],
    methods: ["GET", "POST"],
    paths: ["/api/v1/courses/[[Course ID]]/users", "/api/graphql"],
    request_kvs: [{},{
    "operationName": "CreateConversation",
    "body": "Hi, I have a question about the lab assignment. Can we discuss it?",
    "subject": "Hi!",
    "recipients": ["[[User ID]]"]
    }],
    parameterized_text: 'Task: In the course "[[Course]]" use the People page to search for the user named "[[User]]" view their profile details, and send them a message with the text: "Hi, I have a question about the lab assignment. Can we discuss it?" and the subject line "Hi!".'
  })



  task.populate(test_course) {|course, task|

    user = course.classmates.select {|c| !AgentTask.users.include? c}.first

    if user.nil?
      puts "Could not find unused user for task #{task.id}"
      
      user = course.classmates.select{|c| c != course.logged_in_user}.sample
       
    end

    AgentTask.users << user

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("User", user.name)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("User ID", user.id)
  }

  tasks << task

  task = AgentTask.new({
    id: '2f354ba2-b00c-4f3d-8b05-ae149f8e870d',
    type: 'Information Seeking',
    answer_type: 'Text',
    parameterized_text: 'Task: In the course "[[Course]]" view the page titled "[[Page]]" by navigating to the Pages Index and selecting the page from the list. Return the contents of the page body.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'page',
    test_course.pages,
    lambda{|pages| pages.select{true}},
    task
  ))

  task.populate(test_course) {|course,task|

    page = course.pages.select{|p| !AgentTask.pages.include? p}.first

    if page.nil?
      puts "Could not find page for task #{task.id}"
      return
    end

    AgentTask.pages << page

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Page", page.title)

    task.answer_key = {
      'Text': page.body.strip
    }
  }

  tasks << task

  task = AgentTask.new({
    id: '2fb04821-58a4-4b0e-90b9-2b24882f4582',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: In the course "[[Course]]" use the Quizzes page to find the quiz titled "[[Quiz]]", report the number of questions this quiz has.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda {|quizzes| quizzes.select{true}},
    task
  ))

  task.populate(test_course) {|course, task|

    quiz = course.quizzes.select{|q| !AgentTask.quizzes.include? q}.first

    if quiz.nil?
      puts "Could not find quiz for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)

    task.answer_key = {
      "Number": quiz.quiz_questions.length
    }
  }

  tasks << task

  task = AgentTask.new({
    id: '353feae6-0efa-4913-8220-8ab2567696b4',
    type: 'Information Seeking',
    answer_type: 'Date Time',
    parameterized_text: 'Task: In the "[[Group]]" group, view the revision history of the page titled "[[Page]]" and identify the most recent edit and report when it was made.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| 
    # Fetch group directly from test data to identify pages with update history easily.
    test_data = YAML.load_file $TEST_DATA_PATH
    course_data = test_data["courses"].select{|c|c["name"] == test_course.course.name}.first

    used_group_names = []
    AgentTask.groups.each {|group| used_group_names << group.name}

    group = course_data["groups"].select{|g| (!used_group_names.include? g["name"]) && (!g["pages"].nil?) && (!g["pages"].select{|p| !p["updates"].nil?}.first.nil?)}.first

    groups.select{|g| g.name == group["name"]}},
    task
  ))

  task.populate(test_course) {|course, task|

    # Fetch group directly from test data to identify pages with update history easily.
    test_data = YAML.load_file $TEST_DATA_PATH
    course_data = test_data["courses"].select{|c|c["name"] == course.course.name}.first

    used_group_names = []
    AgentTask.groups.each {|group| used_group_names << group.name}

    group = course_data["groups"].select{|g| (!used_group_names.include? g["name"]) && (!g["pages"].nil?) && (!g["pages"].select{|p| !p["updates"].nil?}.first.nil?)}.first


    if group.nil?
      puts "Could not find a group for task #{task.id}"
      return
    end

    page = group["pages"].select{|p| !p["updates"].nil?}.first

    _group = course.groups.select {|grp| grp.name == group["name"]}.first
    AgentTask.groups << _group

    task.update_initalized_text("Group", group["name"])
    task.update_initalized_text("Page", page["title"])

    _page = _group.wiki_pages.select{|p| 
    
    if true # set true for debugging
      puts "Looking for #{page["updates"][0]['title']}, current page title: #{p.title}"
    end

    p.title == page["updates"][0]['title']}.first

    task.answer_key = {
      "Date Time": _page.revised_at.strftime("%Y-%m-%d %H:%M")
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '37949dc8-cc9a-46ec-9a04-9fc70de7739a',
    type: 'Information Seeking',
    answer_type: 'Date Time',
    parameterized_text: 'Task: In the course "[[Course]]" use the Assignments page to search for the assignment titled "[[Assignment]]". When is this assignment due?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{true}},
    task
  ))

  task.populate(test_course) {|course, task| 

    assignment = course.assignments.select { |a| (!AgentTask.assignments.include? a) }.first

    if assignment.nil?
      puts "Could not find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.answer_key = {
      'Date Time': assignment.due_at.strftime("%Y-%m-%d %H:%M")
    }

  }

  tasks << task


  task = AgentTask.new({
    id: '382d57c2-b2e5-4024-9c05-9c5d195d2a27',
    evaluation_parameters: ["Assignment ID"],
    methods: ["POST"],
    paths: ["/api/v1/planner/overrides"],
    request_kvs: [{
    "marked_complete": true,
    "plannable_id": "[[Assignment ID]]"
    }],
    parameterized_text: 'Task: In the course "[[Course]]" remove the assignment with the title "[[Assignment]]" from your list of To Dos.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments, 
    # Don't select an assignment for which the user has already made a submission as it will no longer appear in the to do list.
    lambda{|assignments| assignments.select{|a| (a.submissions.where(user_id: test_course.logged_in_user).first.body.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    # Don't select an assignment for which the user has already made a submission as it will no longer appear in the to do list.
    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) && (a.submissions.where(user_id: course.logged_in_user).first.body.nil?)}.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return 
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.update_answer_key("Assignment ID", assignment.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '5718e37a-b1d1-4ec9-a223-7fd262419682',
    evaluation_parameters: ["Group ID", "Discussion Message", "Discussion Title"],
    methods: ["POST"],
    paths: ["/api/v1/groups/[[Group ID]]/discussion_topics"],
    request_kvs: [{
    "allow_rating": "1",
    "allow_todo_date": "1",
    "message": "<p>[[Discussion Message]]</p>",
    "title": "[[Discussion Title]]"
    }],
    parameterized_text: 'Task: In your "[[Group]]" group, create a new discussion titled "[[Discussion]]" write "[[Discussion Message]]" allow group members to like the discussion, and add it to other group members\' to-do lists.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| groups.select{|g| (g.users.include? test_course.logged_in_user)}},
    task
  ))

  task.populate(test_course) {|course,task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user)}.first

    if group.nil?
      puts "Could not find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    discussion_data = course.unused_discussions.select{|d| !AgentTask.used_discussions.include? d}.first
    AgentTask.used_discussions << discussion_data

    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Discussion", discussion_data["title"])
    task.update_initalized_text("Discussion Message", discussion_data["message"])

    task.update_answer_key("Discussion Message", discussion_data["message"])
    task.update_answer_key("Discussion Title", discussion_data["title"])
    task.update_answer_key("Group ID", group.id)
  }

  tasks << task

  task = AgentTask.new({
    id: 'a1c4e8bf-af9a-49c5-9672-5e83c0170b9b',
    evaluation_parameters: ["Discussion ID"],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
    "operationName": "CreateDiscussionEntry",
    "discussionTopicId": "[[Discussion ID]]",
    "message": "[[_starts_with='<p>I believe that local communities can play a significant role in addressing climate change by implementing sustainable practices.</p>']]"
    }],
    parameterized_text: 'Task: Reply to the main discussion in the "[[Discussion]]" discussion in the "[[Course]]" course with the following text: "I believe that local communities can play a significant role in addressing climate change by implementing sustainable practices."'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda{|discussions| discussions.select{true}},
    task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| !AgentTask.discussions.include? d}.first
    
    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)

    task.update_answer_key("Discussion ID", discussion.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'a5660a7c-dbac-48d4-ace3-fbd6bb71d57b',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: View the current groups you are enrolled in for the course "[[Course]]" by using the Global Navigation Menu in Canvas. How many groups are you currently a part of?'
  })

  task.populate(test_course) {|course, task|

    task.update_initalized_text("Course", course.course.name)
    task.answer_key = {
      "Number": course.groups.select{|g| g.users.include? course.logged_in_user}.length
    }
  }

  tasks << task

  task = AgentTask.new({
    id: 'a7ab7dbf-7c80-4a13-80a4-f09947504d51',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: Check if you can retake the "[[Quiz]]" in the "[[Course]]" course and report how many attempts you have remaining.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda{|quizzes| quizzes.select{|q| (!q.quiz_submissions.select{|s| (s.user == test_course.logged_in_user) && (s.submission.submission_comments.length == 0)}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course,task|

    quiz = course.quizzes.select{|q| (!AgentTask.quizzes.include? q) && (!q.quiz_submissions.select{|s| (s.user == course.logged_in_user) && (s.submission.submission_comments.length == 0)}.first.nil?)}.first

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    curr_attempts = quiz.quiz_submissions.select{|s| s.user == course.logged_in_user}.max_by(&:attempt)
    
    AgentTask.quizzes << quiz

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)

    task.answer_key = {
      'Number': quiz.allowed_attempts - curr_attempts.attempt
    }
  }

  tasks << task

  task = AgentTask.new({
    id: '1c156f92-b926-4817-b78a-b8ad85de2484',
    type: 'Information Seeking',
    answer_type: 'Text',
    parameterized_text: 'Task: View the comments left by your instructor ([[Teacher]]) on your "[[Assignment]]" assignment in the "[[Course]]" course. What was the feedback [[Teacher]] gave you?',
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a|
      (!a.submissions.where(user_id: test_course.logged_in_user).first.body.nil?) &&
      (!a.submissions.where(user_id: test_course.logged_in_user).first.submission_comments.select{|c| c.author == test_course.teacher}.first.nil?)
    }},
    task
  ))

  task.populate(test_course) {|course,task|

    assignment = course.assignments.select{|a| 

    if false # set to true for debugging
      puts "Assignment: #{a.title}"
      puts "!AgentTask.assignments.include? a #{!AgentTask.assignments.include? a}"
      puts "!a.submissions.where(user_id: course.logged_in_user).first.body.nil? #{!a.submissions.where(user_id: course.logged_in_user).first.body.nil?}"
      puts "Assignment submissions [#{a.submissions.length}]:"
      a.submissions.each_with_index {|s, index| puts "#{index} [#{s.student.name}] [nil:#{s.body.nil?}]: #{s.body}" }

      
      submission = a.submissions.where(user_id: course.logged_in_user).first
      if submission.nil?
        return
      end
      puts "submission #{submission}"
      puts "submission.body #{submission.body}"
      submission.submission_comments.each {|c| puts "Comment: #{c.comment} author: #{c.author}"}
      puts "!a.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| c.author == course.teacher}.first.nil? #{!a.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| c.author == course.teacher}.first.nil?}"
    end

    (!AgentTask.assignments.include? a) && # Find an assignment that hasn't already been used.
       (!a.submissions.where(user_id: course.logged_in_user).first.body.nil?) && # Where the logged in user has made a submission whose body isn't nil
       (!a.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| c.author == course.teacher}.first.nil?) # And the teacher of the course has left a comment on their submission
  
      }.first

    if assignment.nil?
      puts "Could not find assignment for task #{task.id}"
      return
    end

    submission_comment = assignment.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| c.author == course.teacher}.first

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Teacher", course.teacher.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.answer_key = {
      "Text": submission_comment.comment
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '1bfdc4bc-1ab2-4846-b840-4c65d9f9c83f',
    type: 'Information Seeking',
    answer_type: 'Text',
    parameterized_text: 'Task: In the Canvas course "[[Course]]" locate and view the peer feedback you received for the assignment titled "[[Assignment]]" by accessing the submission details page. What was the feedback [[User]] provided to your submission?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a| 
      (!a.submissions.where(user_id: test_course.logged_in_user).first.body.nil?) &&
      (!a.submissions.where(user_id: test_course.logged_in_user).first.submission_comments.select{|c| test_course.classmates.include? c.author}.first.nil?)
      }},
      task
  ))

  task.populate(test_course) {|course, task| 

    assignment = course.assignments.select{|a| 
      (!AgentTask.assignments.include? a) && # Find an assignment that hasn't already been used.
       (!a.submissions.where(user_id: course.logged_in_user).first.body.nil?) && # Where the logged in user has made a submission whose body isn't nil
       (!a.submissions.where(user_id: course.logged_in_user).first.body.nil?) && 
       (!a.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| course.classmates.include? c.author}.first.nil?) # And the teacher of the course has left a comment on their submission
    
      }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    submission_comment = assignment.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| course.classmates.include? c.author}.first

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)
    task.update_initalized_text("User", submission_comment.author.name)

    task.answer_key = {
      "Text": submission_comment.comment
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '229bb30d-7652-40a9-934d-3e14d54e7ab9',
    evaluation_parameters: ["Discussion Reply ID"],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
      "operationName": "UpdateDiscussionEntryParticipant",
      "discussionEntryId": "[[Discussion Reply ID]]",
      "forcedReadState": true,
      "read": false
      }],
    parameterized_text: 'Task: In the course "[[Course]]" open the discussion titled "[[Discussion]]" and manually mark the reply from "[[User]]" as unread.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda {|discussions| discussions.select{|d| (!d.discussion_entries.select{|e| test_course.classmates.include? e.user}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| 

    if false # set to true for debugging
      puts "Discussion: #{d.title}"
      puts "!AgentTask.discussions.include? d #{!AgentTask.discussions.include? d}"
      puts "!d.discussion_entries.select{|e| course.classmates.include? e.user}.first.nil? #{!d.discussion_entries.select{|e| course.classmates.include? e.user}.first.nil?}"
      puts "Entries: #{d.discussion_entries.length}"
      
      d.discussion_entries.each_with_index {|entry, index| 
        puts "[#{index} - #{entry.user.name}] #{entry.message}"
      }

    end
    
    (!AgentTask.discussions.include? d) && (!d.discussion_entries.select{|e| course.classmates.include? e.user}.first.nil?) }.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    AgentTask.discussions << discussion

    reply = discussion.discussion_entries.select{|e| course.classmates.include? e.user}.first
    
    # Ensure the read state of the reply is 'read' so the task makes sense
    reply.change_read_state('read', course.logged_in_user)

    classmate = reply.user

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)
    task.update_initalized_text("User", classmate.name)

    task.update_answer_key("Discussion Reply ID", reply.id)


  }

  tasks << task

  task = AgentTask.new({
    id: '2776ed0f-e34e-4ffc-8884-9720a48a7420',
    evaluation_parameters: ["Announcement ID", "User Name"],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
    "operationName": "CreateDiscussionEntry",
    "discussionTopicId": "[[Announcement ID]]",
    "message": "[[_includes='@[[User Name]]']]"
    }],
    parameterized_text: 'Task: In the course "[[Course]]" reply to the announcement titled "[[Announcement]]" by posting the message "Great announcement, @[[User]]! Looking forward to this week." and mention the user [[User]] in your reply.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'announcement',
    test_course.announcements,
    lambda{|announcements| announcements.select{true}},
    task
  ))

  task.populate(test_course) {|course, task| 

    announcement = course.announcements.select {|a| (!AgentTask.announcements.include? a) }.first

    if announcement.nil?
      puts "Cannot find announcement for task #{task.id}"
      return 
    end

    AgentTask.announcements << announcement


    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Announcement", announcement.title)
    task.update_initalized_text("User", announcement.user.name)

    task.update_answer_key("Announcement ID", announcement.id)
    task.update_answer_key("User Name", announcement.user.name)
  }

  tasks << task

  task = AgentTask.new({
    id:'279dcf3e-77f5-4a1b-8ced-ebdb8bb7e462',
    # Note: User ID here refers to the id of the target user (the one whose work logged_in_user is reviewing)
    evaluation_parameters: ["Course ID", "Assignment ID", "User ID"],
    methods: ["GET", "POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[User ID]]",
            "/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[User ID]]"
    ],
    request_kvs: [{}, {
      "_type": "form data",
      "submission[comment]": ["Great analysis! I especially liked your use of recent data to support your points."]}],
    parameterized_text: 'Task: Submit a peer review comment for the discussion "[[Discussion]]" in the course "[[Course]]" by reviewing [[User]]\'s reply and entering the following comment in the comment sidebar: "Great analysis! I especially liked your use of recent data to support your points." Then, click the Save button to complete the peer review.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda{|discussions| discussions.select{|d| (!d.assignment.nil?)}},
    task
  ))

  task.populate(test_course){ |course,task|

    discussion = course.discussions.select{|d| (!AgentTask.discussions.include? d) && (!d.assignment.nil?)}.first 

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    AgentTask.discussions << discussion

    assessment = AssessmentRequest.for_assignment(discussion.assignment.id).select{|a| a.assessor == course.logged_in_user}.first
    target_student = assessment.user.name

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)
    task.update_initalized_text("User", target_student)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", discussion.assignment.id)
    task.update_answer_key("User ID", assessment.user.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '29d80dd0-2506-41bc-ad55-40db3359b84c',
    evaluation_parameters: ["Course ID", "Last Question ID", "Quiz ID"],
    methods: ["POST", "POST"],                                                            
    paths: ["/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions/[[ANY]]/record_answer?next_question_path=%2Fcourses%2F[[Course ID]]%2Fquizzes%2F[[Quiz ID]]%2Ftake%2Fquestions%2F[[Question ID]]",
      "/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions"
    ],
    request_kvs: [{}, {}],
    parameterized_text: 'Task: Take the quiz titled "[[Quiz]]" in the course "[[Course]]" answering each question as it appears on the screen, and use the Next button to advance to the next question after answering. Do not leave any question blank.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda{|quizzes| quizzes.select{|q| q.one_question_at_a_time}},
    task
    ))

  task.populate(test_course){|course,task|

    quiz = course.quizzes.select{|q|
    
    if false # Set to true for debugging
      puts "Quiz: #{q.title} - one_question_at_a_time? #{q.one_question_at_a_time}"
    end
    
    (!AgentTask.quizzes.include? q) && q.one_question_at_a_time}.first

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    task.update_initalized_text('Course', course.course.name)
    task.update_initalized_text('Quiz', quiz.title)

    submission = quiz.assignment.submissions.find_by(user_id: course.logged_in_user.id)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Last Question ID", quiz.quiz_questions.last.id )
    task.update_answer_key("Quiz ID", quiz.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '3b389112-ccb7-4272-853e-8dbe81a1c6c8',
    evaluation_parameters: ["Group ID", "Page Slug"],
    methods: ["DELETE"],
    paths: ["/api/v1/groups/[[Group ID]]/pages/[[Page Slug]]"],
    request_kvs: [{}],
    parameterized_text: 'Task: Delete the page titled "[[Page]]" from the "[[Group]]" group in your [[Course]] course in Canvas.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| groups.select{|g| (g.users.include? test_course.logged_in_user) && (g.wiki_pages.length >= 1)}},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| 
    
    if false # set to true for debugging
      puts "Group: #{g.name}"
      puts "!AgentTask.groups.include? g #{!AgentTask.groups.include? g}"
      puts "g.users.include? course.logged_in_user #{g.users.include? course.logged_in_user}"
      puts "g.wiki_pages.length >= 1 #{g.wiki_pages.length >= 1}"
    end

    (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user) && (g.wiki_pages.length >= 1) }.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    page = group.wiki_pages.first

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Page", page.title)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Page Slug", page.url)

  }

  tasks << task

  task = AgentTask.new({
    id: '45974a3d-36dc-409e-9fe4-8cbd0adc3517',
    evaluation_parameters: ["Group ID", "Discussion ID"],
    methods: ["DELETE"],
    paths: ["/api/v1/groups/[[Group ID]]/discussion_topics/[[Discussion ID]]"],
    request_kvs: [{}],
    parameterized_text: 'Task: Delete the announcement titled "[[Announcement]]" from the "[[Group]]" group in the [[Course]] course on Canvas.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| groups.select{|g| (g.users.include? test_course.logged_in_user) && (!g.announcements.select{|a| a.user == test_course.logged_in_user}.first.nil?) }},
    task
    ))


  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? test_course.logged_in_user) && (!g.announcements.select{|a| a.user == course.logged_in_user}.first.nil?) }.first

    if group.nil?
      puts "Could not find group for task #{task.id}"
      return
    end

    AgentTask.groups << group
    
    announcement = group.announcements.select{|a| a.user == course.logged_in_user}.first

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Announcement", announcement.title)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Discussion ID", announcement.id)

  }

  tasks << task

  # Commented out as it is a duplicate of '1bfdc4bc-1ab2-4846-b840-4c65d9f9c83f'
  # task = AgentTask.new({
  #   id: '4bbdbb35-c934-40ab-a042-034f04e2de77',
  #   parameterized_text: 'Task: View the peer feedback you received on the "[[Assignment]]" assignment in the "[[Course]]" course using the Assignment Details page.'
  # })

  # task.populate(test_course) {|course, task| 

  #   assignment = course.assignments.select{|a| 
  #     (!AgentTask.assignments.include? a) && # Find an assignment that hasn't already been used.
  #      (!a.submissions.where(user_id: course.logged_in_user).first.body.nil?) && # Where the logged in user has made a submission whose body isn't nil
  #      ((a.rubric_association.nil?) || (a.rubric_association.rubric_assessments.length == 0)) && # Don't use up assignments with rubric assessments for this task.
  #      (!a.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| course.classmates.include? c.author}.first.nil?) && (!a.submission_types.include? "online_url") # And the teacher of the course has left a comment on their submission

  #     }.first

  #   if assignment.nil?
  #     puts "Cannot find assignment for task #{task.id}"
  #     return
  #   end

  #   AgentTask.assignments << assignment

  #   task.update_initalized_text("Course", course.course.name)
  #   task.update_initalized_text("Assignment", assignment.title)

  # }

  # tasks << task

  task = AgentTask.new({
    id: '6242d2f1-f67e-4d56-a856-b9a5f536672f',
    evaluation_parameters: ["Course ID", "Discussion Title", "Discussion Message"],
    methods: ["POST"],
    paths: ["/api/v1/courses/[[Course ID]]/discussion_topics"],
    request_kvs: [{
    "title": "[[Discussion Title]]",
    "message": "<p>[[Discussion Message]]</p>"
    }],
    parameterized_text: 'Task: In the course "[[Course]]" create a new course discussion titled "[[Discussion]]" In the discussion content, enter the following text: "[[Discussion Message]]" Save the discussion.'
  })

  task.populate(test_course) {|course, task|
    
    discussion_data = course.unused_discussions.select{|d| !AgentTask.used_discussions.include? d}.first

    AgentTask.used_discussions << discussion_data

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion_data["title"])
    task.update_initalized_text("Discussion Message", discussion_data["message"])

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Discussion Title", discussion_data["title"])
    task.update_answer_key("Discussion Message", discussion_data["message"])
  }

  tasks << task

  task = AgentTask.new({
    id: 'b18ec1c0-213c-480c-8c5e-b770e86e8c76',
    evaluation_parameters: ["Group ID","Page Title", "Page Body"],
    methods: ["POST"],
    paths: ["/api/v1/groups/[[Group ID]]/pages"],
    request_kvs: [{
    "title": "[[Page Title]]",
    "body": "[[_includes='[[Page Body]]']]",
    "editing_roles": "members,public",
    "notify_of_update": "1"
    }],
    parameterized_text: 'Task: In the "[[Group]]" group create a new group page titled "[[Page]]". In the page content, enter the following text: "[[Page Message]]" Set the page so that anyone can edit it, and check the box to notify users that this content has changed. Save the page.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g| (g.users.include? test_course.logged_in_user)}},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    page_data = course.unused_pages.select{|p| !AgentTask.used_pages.include? p}.first
    AgentTask.used_pages << page_data

    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Page", page_data["title"])
    task.update_initalized_text("Page Message", page_data["message"])

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Page Title", page_data["title"])
    task.update_answer_key("Page Body", page_data["message"])
  }

  tasks << task

  task = AgentTask.new({
    id: 'b68ad0fe-8cd4-40b1-ad7f-88b43510da75',
    evaluation_parameters: ["Course ID", "User ID", "Assignment ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[User ID]]"],
    request_kvs: [{
    "_type": "form data",
    "submission[comment]": "[[_includes='Great feedback received!']]"
    }],
    parameterized_text: 'Task: Add a text comment with an emoji to your submission for the assignment "[[Assignment]]" in the course "[[Course]]" saying "Great feedback received!".'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments, 
    lambda {|assignments| assignments.select{|a| 
      (!a.submissions.where(user_id: test_course.logged_in_user).first.body.nil?) &&
      (!a.submissions.where(user_id: test_course.logged_in_user).first.submission_comments.select{|c| test_course.classmates.include? c.author}.first.nil?)
      }},
      task
  ))

  task.populate(test_course) {|course, task|
    assignment = course.assignments.select{|a| 
      (!AgentTask.assignments.include? a) && # Find an assignment that hasn't already been used.
       (!a.submissions.where(user_id: course.logged_in_user).first.body.nil?) && # Where the logged in user has made a submission whose body isn't nil
       (!a.submissions.where(user_id: course.logged_in_user).first.submission_comments.select{|c| course.classmates.include? c.author}.first.nil?) # And the teacher of the course has left a comment on their submission

      }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    submission = assignment.submissions.find_by(user_id: course.logged_in_user.id)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("User ID", course.logged_in_user.id)
    task.update_answer_key("Assignment ID", assignment.id)
  }

  tasks << task

  task = AgentTask.new({
    id: 'bd1583a6-7c16-4d45-9cfb-e6bce6d088a0',
    type: 'Information Seeking',
    answer_type: 'Text',
    parameterized_text: 'Task: Check if you have a peer review discussion to complete for the course "[[Course]]" and identify the name of a student whose post you need to review.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda{|discussions| discussions.select{|d| 
      (!d.assignment.nil?) &&
      (d.discussion_entries.length >= 2) && 
      (!d.discussion_entries.select{|e| e.user == test_course.logged_in_user}.first.nil?)
      }},
      task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| (!AgentTask.discussions.include? d) && (!d.assignment.nil?) && (d.discussion_entries.length >= 2) && (!d.discussion_entries.select{|e| e.user == course.logged_in_user}.first.nil?)}.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    AgentTask.discussions << discussion
    # AgentTask.assignments << discussion.assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)
    
    task.answer_key = {
      "Text": AssessmentRequest.for_assignment(discussion.assignment.id).select{|a| a.assessor == course.logged_in_user}.map{|a| a.user.name}
    }
    


  }

  tasks << task

  task = AgentTask.new({
    id: '681d72b5-e5fb-4895-960c-f5127e10fcac',
    evaluation_parameters: ["Course ID", "Module ID","Item ID"],
    methods: ["POST"],
    paths: ["/api/v1/courses/[[Course ID]]/modules/[[Module ID]]/items/[[Item ID]]/done"],
    request_kvs: [{}],
    parameterized_text: 'Task: In the course "[[Course]]" go to the Modules section and find the module called "[[Module Name]]". Under that module mark the content page titled "[[Page]]" as done.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'module',
    test_course.modules,
    lambda {|_modules| _modules.select{|m| (!m.content_tags.select{|i| i.content_type == 'WikiPage'}.first.nil?)} },
    task
  ))

  task.populate(test_course) {|course, task|

    _module = course.modules.select{|m| 
    
    if false # set to true for debugging
      puts "Module: #{m.name}"
      puts "items:"
      m.content_tags.each_with_index{|item, index|
        puts "#{index} [#{item.content_type}]: #{item.content_id}"
      }

    end
    
    (!AgentTask.modules.include? m) && (!m.content_tags.select{|i| i.content_type == 'WikiPage'}.first.nil?)}.first

    if _module.nil?
      puts "Cannot find module for task #{task.id}"
      return
    end

    AgentTask.modules << _module

    page_id = _module.content_tags.select{|i| i.content_type == 'WikiPage'}.first.content_id
    item_id = _module.content_tags.select{|i| i.content_id == page_id}.first.id

    puts "looking for page with id #{page_id} in #{course.course.name}"
    page = course.pages.select{|p| 
    puts "Page: [#{p.id}] #{p.title}"
    p.id == page_id}.first
    
    AgentTask.pages << page

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Page", page.title)
    task.update_initalized_text("Module Name", _module.name)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Module ID", _module.id)
    task.update_answer_key("Item ID", item_id) # TODO: Verify this. 
  }

  tasks << task

  task = AgentTask.new({
    id: '0455d1fc-9c89-490f-aea1-f6234029f2ba',
    type: 'Information Seeking',
    answer_type: 'Date Time',
    parameterized_text: 'Task: Verify that you have successfully submitted your "[[Assignment]]" assignment in the "[[Course]]" course by viewing the submission confirmation details. What is the date time that you made your submission?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a|(!a.submissions.where(user_id: test_course.logged_in_user).first.body.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) &&
      (!a.submissions.where(user_id: course.logged_in_user).first.body.nil?)}.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    submission = assignment.submissions.where(user_id: course.logged_in_user).first

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.answer_key = {
      "Date Time": submission.submitted_at.strftime("%Y-%m-%d %H:%M")
    }


  }

  tasks << task

  task = AgentTask.new({
    id: 'e0cfbef6-1383-463e-ac40-db871e962295',
    evaluation_parameters: ["Group ID", "Group Name"],
    methods: ["POST"],
    paths: ["/api/v1/groups/[[Group ID]]"], 
    request_kvs: [{
    "name": ["[[Group Name]]"]
    }],
    parameterized_text: 'Task: As the student group leader of "[[Group 1]]" in the "[[Course]]" course, change your group\'s name to "[[Group 2]]".'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| groups.select{|g|
    (!g.leader.nil?) &&
    (g.leader == test_course.logged_in_user)
    }},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select {|g| 

      if false # Set to true for debugging
        puts "Group: #{g.name}"
        puts "!AgentTask.groups.include? g: #{!AgentTask.groups.include? g}"
        puts "Group leader exists? #{!g.leader.nil?}"
        if g.leader
          puts "Group leader: #{g.leader.name}"
          puts "g.leader == course.logged_in_user? #{g.leader == course.logged_in_user}"
        end
      end
      
      (!AgentTask.groups.include? g) && # Find a group that's not yet used by some other task.
      (!g.leader.nil?) && # Which has a leader specified.
      (g.leader == course.logged_in_user) # And whose leader is the logged in user. 
    }.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return 
    end

    AgentTask.groups << group # Mark this group as used

    new_group_name = course.unused_group_names.select {|name| !AgentTask.used_group_names.include? name}.first # Find an unused group name
    AgentTask.used_group_names << new_group_name # Mark this group name as used.

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group 1", group.name)
    task.update_initalized_text("Group 2", new_group_name)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Group Name", new_group_name)

  }

  tasks << task

  task = AgentTask.new({
    id: 'bc69c1dc-3ccc-4cef-80ec-ed2a5d931c5e',
    evaluation_parameters: ["Group ID", "User ID"],
    methods: ["POST"], 
    paths: ["/api/v1/groups/[[Group ID]]"],
    request_kvs: [{
    "_method": "PUT",
    "members[]": "[[_array_not_contains='[[User ID]]']]"
    }],
    parameterized_text: 'Task: As the student group leader of "[[Group]]" in the "[[Course]]" course, remove the member named "[[User]]" from the group. Submit your changes.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g| (!g.leader.nil?) && (g.leader == test_course.logged_in_user) && (g.users.length >= 2) }},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (!g.leader.nil?) && (g.leader == course.logged_in_user)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    other_members = group.users.select{|u| u != course.logged_in_user}
    user_to_remove = other_members.sample

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("User", user_to_remove.name )

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("User ID", user_to_remove.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '8d2b6c85-7bc4-4683-b468-bf85542aa2c7',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: View the peer review rubric assessment and comments left by [[User]] for the assignment "[[Assignment]]" in the course "[[Course]]". How many points did [[User]] give you for the first criteria in the rubric?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda {|assignments| assignments.select{|a| 
      (!a.rubric_association.nil?) && 
      (a.rubric_association.rubric_assessments.length > 0) &&
      (!a.rubric_association.rubric_assessments.select{|assessment| (assessment.user == test_course.logged_in_user) && (test_course.classmates.include? assessment.assessor) }.first.nil?)
      }},
      task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| 
      (!AgentTask.assignments.include? a) && 
      (!a.rubric_association.nil?) &&
      (a.rubric_association.rubric_assessments.length > 0) &&
      (!a.rubric_association.rubric_assessments.select{|assessment| (assessment.user == course.logged_in_user) && (course.classmates.include? assessment.assessor) }.first.nil?) 
    }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return 
    end

    AgentTask.assignments << assignment

    assessment = assignment.rubric_association.rubric_assessments.select{|assessment| (assessment.user == course.logged_in_user) && (course.classmates.include? assessment.assessor)}.first


    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)
    task.update_initalized_text("User", assessment.assessor.name)
    
    task.answer_key = {
      "Number": assessment.data[0]["points"].round
    }

  }

  tasks << task

  task = AgentTask.new({
    id: 'c9819826-9891-4b9a-824b-f94f91a6598b',
    evaluation_parameters: ["Course ID", "Assignment ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[ANY]]"],
    request_kvs: [{
    "_type":"form data",
    "submission[comment]": ["Great job but consider adding more sources to support your arguments."]
    }],
    parameterized_text: 'Task: Complete a peer review for the assignment "[[Assignment]]" in the course "[[Course]]" by leaving the following comment in the comment sidebar: "Great job but consider adding more sources to support your arguments." Submit your assessment to finish the peer review.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a| 
      (AssessmentRequest.for_assignment(a.id).length > 0) && 
      (!AssessmentRequest.for_assignment(a.id).select{|request| request.assessor == test_course.logged_in_user}.first.nil?)
      }},
      task
  ))

  task.populate(test_course) { |course, task|

    assignment = course.assignments.select{|a| 
      assessment_requests = AssessmentRequest.for_assignment(a.id)
      
      if false # Set to true for debugging
        puts "Found #{assessment_requests.length} assessment requests for Assignment (#{a.title})"
        puts "AssessmentRequests.length > 0? #{assessment_requests.length > 0}"
        puts assessment_requests

        puts "Submission types for this assignment: #{a.submission_types}"
        puts "a.submission_types.include?\"discussion_topic\": #{a.submission_types.include?"discussion_topic"}"

      end

      (!AgentTask.assignments.include? a) && 
      (AssessmentRequest.for_assignment(a.id).length > 0) &&
      (!AssessmentRequest.for_assignment(a.id).select{|request| request.assessor == course.logged_in_user}.first.nil?)
    }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment
    
    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", assignment.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '42ad8db4-826a-414a-9ad6-b5c9abd93078',
    evaluation_parameters: ["Discussion Reply ID"],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
    "operationName": "UpdateDiscussionEntryParticipant",
    "rating": "liked",
    "discussionEntryId": "[[Discussion Reply ID]]"
    }],
    parameterized_text: 'Task: In the course "[[Course]]" open the discussion titled "[[Discussion]]" locate the reply by student "[[User]]" and click the Like icon to like this reply.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda {|discussions| discussions.select{|d| (d.allow_rating == true) &&  (d.discussion_entries.length > 0)}},
    task
  ))

  task.populate(test_course){|course, task|

    discussion = course.discussions.select{|d| (!AgentTask.discussions.include? d) && (d.allow_rating == true) && (d.discussion_entries.length > 0)}.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return 
    end
    AgentTask.discussions << discussion


    reply = discussion.discussion_entries.sample

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)
    task.update_initalized_text("User", reply.user.name)

    task.update_answer_key("Discussion Reply ID", reply.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '542dda0b-1dd9-4c1b-86b3-7343786c226c',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: View the rubric results for your submission to the assignment "[[Assignment]]" in the course "[[Course]]". How many points did you recieve for the [[Criteria]] criteria in the rubric?' 
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a|
      (!a.rubric_association.nil?) &&
      (a.rubric_association.rubric_assessments.length > 0) &&
      (!a.rubric_association.rubric_assessments.select{|assessment| assessment.assessor == test_course.teacher}.first.nil?)
    }},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| 
    
    if false # Set to true for debugging
      puts "For assignment #{a.title}"
      puts "!AgentTask.assignments.include? a #{!AgentTask.assignments.include? a}"
      puts "a.rubric_associaton.nil? #{a.rubric_association.nil?}"
      if !a.rubric_association.nil?
        puts "a.rubric_association.rubric_assessments.length: #{a.rubric_association.rubric_assessments.length}"
        puts "!a.rubric_association.rubric_assessments.select{|assessment| assessment.assessor == course.teacher}.first.nil? #{!a.rubric_association.rubric_assessments.select{|assessment| assessment.assessor == course.teacher}.first.nil?}"
      end
    end
    
    (!AgentTask.assignments.include? a) && 
      (!a.rubric_association.nil?) &&
      (a.rubric_association.rubric_assessments.length > 0) &&
      (!a.rubric_association.rubric_assessments.select{|assessment| assessment.assessor == course.teacher}.first.nil?) 
    }.first

    if assignment.nil? 
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)
    task.update_initalized_text("Criteria", assignment.rubric_association.rubric.data[0][:description])

    task.answer_key = {
      "Number": assignment.rubric_association.rubric.data[0][:points]
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '6f4fd860-3339-4de0-9172-d18ac3a6d89f',
    evaluation_parameters: ["Discussion ID"],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
      "operationName": "CreateDiscussionEntry",
      "discussionTopicId": "[[Discussion ID]]",
      "message": "[[_starts_with='<p>Thank you for the information! Looking forward to this semester.</p>']]"
    }],
    parameterized_text: 'Task: Reply to the announcement titled "[[Announcement]]" in the "[[Course]]" course with the message: "Thank you for the information! Looking forward to this semester."'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'announcement',
    test_course.announcements,
    lambda{|announcements| announcements.select{true}},
    task
  ))

  task.populate(test_course){|course,task|

    announcement = course.announcements.select{|a|
      (!AgentTask.announcements.include? a)
    }.first

    if announcement.nil?
      puts "Cannot find announcement for task #{task.id}"
      return
    end

    AgentTask.announcements << announcement

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Announcement", announcement.title)

    task.update_answer_key("Discussion ID", announcement.id)

  }

  tasks << task

  task = AgentTask.new({
    id:'72966af5-5445-4226-8236-e94352fb514b',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: In the course "[[Course]]" open the discussion titled "[[Discussion]]". How many replies are there for this discussion?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda {|discussions| discussions.select{|d| (d.discussion_entries.length > 0)}},
    task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| 
      (!AgentTask.discussions.include? d) &&
      (d.discussion_entries.length > 0)
    }.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)

    task.answer_key = {
      'Number': discussion.discussion_entries.length
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '0e27e906-bd1d-4ecb-957f-f8acb9c51e08',
    evaluation_parameters: [],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
    "operationName": "UpdateDiscussionEntryParticipant",
    "reportType": "inappropriate"
    }],
    parameterized_text: 'Task: In the course "[[Course]]" report a reply in the discussion titled "[[Discussion]]" as inappropriate. Select "inappropriate" as the reason for reporting and submit your report.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda{|discussions| discussions.select{|d| (d.discussion_entries.length > 0)}},
    task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| (!AgentTask.discussions.include? d) && (d.discussion_entries.length > 0)}.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)

  }

  tasks << task

  task = AgentTask.new({
    id: '8aa2d6ba-d913-4972-ac2a-0056fc386691',
    evaluation_parameters: [],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
    "operationName": "UpdateDiscussionEntry",
    "message": "<p>I believe renewable energy is essential for our future.</p>"
    }],
    parameterized_text: 'Task: In your [[Course]] course, edit your reply in the "[[Discussion]]" discussion by changing the text to "I believe renewable energy is essential for our future." and save your changes.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda{|discussions| discussions.select{|d| 
      (d.discussion_entries.length > 0) &&
      (d.discussion_entries.select{|e| e.user == test_course.logged_in_user}.length == 1)
    }},
    task
  ))

  task.populate(test_course){|course, task|

    discussion = course.discussions.select{|d| 
    
    if false # set to true for debugging
      puts "Discussion: #{d.title}"
      puts "!AgentTask.discussions.include? d #{!AgentTask.discussions.include? d}"
      puts "d.discussion_entries.length > 0: #{d.discussion_entries.length > 0}"
      puts "d.discussion_entries.select{|e| e.user == course.logged_in_user}.length == 1: #{!d.discussion_entries.select{|e| e.user == course.logged_in_user}.length == 1}"
      puts "d.discussion_entries.select{|e| e.user == course.logged_in_user}.length: #{d.discussion_entries.select{|e| e.user == course.logged_in_user}.length}"
    end
    
    (!AgentTask.discussions.include? d) && 
      (d.discussion_entries.length > 0) &&
      (d.discussion_entries.select{|e| 
        if false # set to true for debugging
          puts "Found a reply by #{e.user.name}"
          puts "e.user == course.logged_in_user? #{e.user == course.logged_in_user}"
        end
        e.user == course.logged_in_user}.length == 1)
    }.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return 
    end

    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)
  }

  tasks << task

  task = AgentTask.new({
    id: '8be2d07d-8263-4add-9198-662264777c6c',
    evaluation_parameters: ["Discussion ID","Discussion Reply ID"],
    methods: ["POST"],
    paths: ["/api/graphql"],
    request_kvs: [{
    "operationName": "CreateDiscussionEntry",
    "discussionTopicId": "[[Discussion ID]]",
    "message": "<p>Thank you for the clarification!</p>",
    "quotedEntryId": "[[Discussion Reply ID]]"
    }],
    parameterized_text: 'Task: In the "[[Announcement]]" announcement for the "[[Course]]" find the reply by [[Author]] that says: "[[Quoted Reply Text]]" and use the Quote Reply feature to respond to them with the text "Thank you for the clarification!".'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'announcement',
    test_course.announcements,
    lambda{|announcements| announcements.select{|a|(a.discussion_entries.length > 0) }},
    task
  ))

  task.populate(test_course) {|course, task|
  
    announcement = course.announcements.select{|a| (!AgentTask.announcements.include? a) && (a.discussion_entries.length > 0)}.first

    if announcement.nil?
      puts "Cannot find announcement for task #{task.id}"
      return
    end

    AgentTask.announcements << announcement

    last_reply = announcement.discussion_entries.last

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Announcement", announcement.title)
    task.update_initalized_text("Author", last_reply.user.name)
    task.update_initalized_text("Quoted Reply Text", last_reply.message)

    

    task.update_answer_key("Discussion ID", announcement.id)
    task.update_answer_key("Discussion Reply ID", last_reply.id )

  }

  tasks << task

  task = AgentTask.new({
    id: '9151a1c8-9803-4a89-b6a4-4b6dfa2190cf',
    evaluation_parameters: ["Group ID"],
    methods: ["POST"],
    paths: ["/api/v1/groups/[[Group ID]]/external_feeds"],
    request_kvs: [{
    "header_match": "AI",
    "url": "https://news.ycombinator.com/rss",
    "verbosity": "full"
    }],
    parameterized_text: 'Task:  Add the external RSS feed "https://news.ycombinator.com/rss" to the "[[Group]]" group announcements in Canvas, set it to display only posts with the phrase "AI" in the title, and choose the "Full article" option for content display.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda{|groups| groups.select{|g| (g.users.include? test_course.logged_in_user)}},
    task
  ))

  task.populate(test_course){|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    task.update_initalized_text("Group", group.name)

    task.update_answer_key("Group ID", group.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '96290cff-cfa7-4712-8f63-0a853cdbf0c7',
    type: 'Information Seeking',
    answer_type: 'Text',
    parameterized_text: 'Task: Locate and open your assigned peer review for the "[[Assignment]]" assignment in the "[[Course]]" course using the To Do list on your Canvas Dashboard. What is the name of the student whose submission you are reviewing?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda {|assignments| assignments.select{|a| (!AssessmentRequest.for_assignment(a.id).select{|assessment| assessment.assessor == test_course.logged_in_user}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) && 
      (!AssessmentRequest.for_assignment(a.id).select{|assessment| assessment.assessor == course.logged_in_user}.first.nil?)
    }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.answer_key = {
      "Text": AssessmentRequest.for_assignment(assignment.id).select{|a| a.assessor == course.logged_in_user}.map{|a| a.user.name}
    }

  }

  tasks << task

  task = AgentTask.new({
    id: '98d2e0b9-478c-4eec-b40b-82a61e78ba87',
    evaluation_parameters: ["Course ID", "Assignment ID", "User ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[User ID]]"],
    request_kvs: [{
    "_type": "form data",
    "submission[student_entered_score]": ["85"]
    }],
    parameterized_text: 'Task: In the course "[[Course]]" use the What-If Grades feature to enter a hypothetical score of 85 for the assignment "[[Assignment]]" and view how this affects your total grade.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments, 
    lambda{|assignments| assignments.select{|a|
      # Only select from assignments that don't have associated discussion topics.
      #!test_course.discussions.select{|d| !d.assignment.nil?}.map{|d| d.assignment}.include? a
      true
    }},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a)}.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    submission = assignment.submissions.find_by(user_id: course.logged_in_user.id)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", assignment.id)
    task.update_answer_key("User ID", course.logged_in_user.id)

  }

  tasks << task

  task = AgentTask.new({
    id: '9b7f10f1-60fe-4bbe-968c-9b828cdbeb8f',
    evaluation_parameters: ["Group ID", "Page Slug", "Page Title"],
    methods: ["PUT"],
    paths: ["/api/v1/groups/[[Group ID]]/pages/[[Page Slug]]"],
    request_kvs: [{
      "title": "Final [[Page Title]]",
      "body": "[[_starts_with='<p>This is the finalized version of our group research outline for submission.']]"

      }],
    parameterized_text: 'Task: In the "[[Group]]" group, edit the page titled "[[Page]]" by changing its title to "Final [[Page]]" and adding the following text to the top of the page: "This is the finalized version of our group research outline for submission." Save your changes.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g| (g.wiki_pages.length > 0) }},
    task
  ))

  task.populate(test_course) {|course, task| 
    group = course.groups.select{|g| 
    
    if false # set to true for debugging
      puts "For group #{g.name}"
      puts "!AgentTask.groups.include? g #{!AgentTask.groups.include? g}"
      puts "g.wiki_pages.length > 0: #{g.wiki_pages.length > 0}"
    end
    
    (!AgentTask.groups.include? g) && (g.wiki_pages.length > 0)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    page = group.wiki_pages.first
    
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Page", page.title)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Page Slug", page.url)
    task.update_answer_key("Page Title", page.title)
    
  }

  tasks << task

  task = AgentTask.new({
    id: 'aa62cf92-1cdd-4b30-b49c-9f4e8791776f',
    type: 'Information Seeking',
    answer_type: 'Text',
    parameterized_text: 'Task: View the rubric for the assignment titled "[[Assignment]]" in the course "[[Course]]" by navigating to the Assignments page, clicking on "[[Assignment]]" and locating the rubric displayed below the assignment instructions. What is the heading of the rubric for this assignment?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a| (!a.rubric_association.nil?) }},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) && (!a.rubric_association.nil?)
    }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)
    
    task.answer_key = {
      "Text": assignment.rubric_association.rubric.title
    }
  }

  tasks << task

  task = AgentTask.new({
    id: 'c7a8b1a8-cd2c-4581-9cc3-89d2a1a4f788',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: View the rubric for the graded discussion titled "[[Discussion]]" in the course "[[Course]]" by navigating to the Discussions section, selecting the discussion, and opening the rubric. How many points can you score for the first criteria of the rubric?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda {|discussions| discussions.select{|d| (!d.assignment.nil?) && (!d.assignment.rubric_association.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    discussion = course.discussions.select{|d| (!AgentTask.discussions.include? d) && (!d.assignment.nil?) && (!d.assignment.rubric_association.nil?)}.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    rubric = discussion.assignment.rubric_association.rubric

    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)

    task.answer_key = {
      "Number": rubric.data[0][:points]
    }
    
  }

  tasks << task

  task = AgentTask.new({
    id: 'cfb8fa30-c680-4b13-9dd0-d49e4567ff15',
    evaluation_parameters: ["Course ID", "Assignment ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions"],
    request_kvs: [{
    "_type": "form data",
    "submission[url]": "[[_array_contains='https://www.exampleproject.com']]"
    }],
    parameterized_text: 'Task: Submit the URL "https://www.exampleproject.com" as your assignment submission for the assignment titled "[[Assignment]]" in the course "[[Course]]" on Canvas.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda{|assignments| assignments.select{|a| (a.submission_types.include? "online_url") }},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) && (a.submission_types.include? "online_url")}.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", assignment.id)

  }

  tasks << task

  # Commented as it is a duplicate of: 9b7f10f1-60fe-4bbe-968c-9b828cdbeb8f and b18ec1c0-213c-480c-8c5e-b770e86e8c76
  # task = AgentTask.new({
  #   id: 'd5654365-86b6-4df1-ada7-a27b37be2042',
  #   parameterized_text: 'Task: Edit the "[[Page]]" page for your group ([[Group]]) in the "[[Course]]" course to add the following text at the end of the page: "All group members must submit their individual reports by next week." Check the box to notify users that the content has changed, then save your changes.'
  # })

  # task.populate(test_course) {|course, task|

  #   group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.wiki_pages.length > 0)}.first

  #   if group.nil?
  #     puts "Cannot find group for task #{task.id}"
  #     return
  #   end

  #   AgentTask.groups << group

  #   page = group.wiki_pages.first

  #   task.update_initalized_text("Course", course.course.name)
  #   task.update_initalized_text("Group", group.name)
  #   task.update_initalized_text("Page", page.title)

  # }

  # tasks << task

  task = AgentTask.new({
    id: 'd6ac9877-e256-4487-86cc-2bb0b085c804',
    evaluation_parameters: ["Course ID", "Announcement Title"],
    methods: ["GET", "PUT"],
    paths: ["/api/v1/courses/[[Course ID]]/discussion_topics?search_term=[[Announcement Title]]",
      "/api/v1/courses/[[Course ID]]/discussion_topics/read_all"],
    request_kvs: [{},{}],
    parameterized_text: 'Task: In the course "[[Course]]" use the search field in the Announcements Index Page to find the announcement titled "[[Announcement]]". Then, mark all announcements as read using the "Mark All as Read" button.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'announcement',
    test_course.announcements,
    lambda {|announcements| announcements.select{true}},
    task
  ))

  task.populate(test_course) {|course, task|

    announcement = course.announcements.select{|a| (!AgentTask.announcements.include? a)}.first

    if announcement.nil?
      puts "Cannot find announcement for task #{task.id}"
      return
    end

    AgentTask.announcements << announcement

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Announcement", announcement.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Announcement Title", ERB::Util.url_encode(announcement.title))

  }

  tasks << task

  task = AgentTask.new({
    id: 'd8f661f0-6bcc-4778-8b5e-ed716f425cd8',
    evaluation_parameters: ["Course ID", "Assignment ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions"],
    request_kvs: [{
    "_type": "form data",
    "submission[body]": ["<p>The most interesting concept I learned this week was cognitive dissonance.</p>"]
    }],
    parameterized_text: 'Task: Submit a text entry for the [[Assignment]] assignment in the course "[[Course]]" by entering the text "The most interesting concept I learned this week was cognitive dissonance."'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda {|assignments| assignments.select{|a| (a.submission_types.include? "online_text_entry")}},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) && (a.submission_types.include? "online_text_entry")}.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", assignment.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'db729474-de9b-410b-9476-7e1b49775d3a',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: Check if your instructor has graded your "[[Assignment]]" assignment in the "[[Course]]" course and note the score you received.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'assignment',
    test_course.assignments,
    lambda {|assignments| assignments.select{|a| (!a.submissions.select{|s| (s.user == test_course.logged_in_user) && (s.graded?)}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    assignment = course.assignments.select{|a| (!AgentTask.assignments.include? a) && 
      (!a.submissions.select{|s| (s.user == course.logged_in_user) && (s.graded?)}.first.nil?)
    }.first

    if assignment.nil?
      puts "Cannot find assignment for task #{task.id}"
      return
    end

    AgentTask.assignments << assignment

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)

    submission = assignment.submissions.where(user_id: course.logged_in_user).first

    task.answer_key = {
      "Number": submission.grade.to_i
    }

  }

  tasks << task

  task = AgentTask.new({
    id: 'e070c0de-41d2-42aa-8a7c-c93f98fdc4c4',
    evaluation_parameters: ["Group ID", "Discussion ID"],
    methods: ["PUT"],
    paths: ["/api/v1/groups/[[Group ID]]/discussion_topics/[[Discussion ID]]"],
    request_kvs: [{
    "message": "<p>Our first group meeting will be held on Friday at 3 PM in the atrium.</p>"
    }],
    parameterized_text: 'Task: Edit the announcement titled "[[Announcement]]" in the group [[Group]] in the [[Course]] course by changing the content to "Our first group meeting will be held on Friday at 3 PM in the atrium." Then, click the Save button to save your changes.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g| (g.users.include? test_course.logged_in_user) && (!g.announcements.select{|a| a.user == test_course.logged_in_user}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course,task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user) && (!g.announcements.select{|a| a.user == course.logged_in_user}.first.nil?)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    announcement = group.announcements.select{|a| a.user == course.logged_in_user}.first

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Announcement", announcement.title)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Discussion ID", announcement.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'e178ca11-ad42-4c2e-811c-cb3c25177dc8',
    evaluation_parameters: ["Embed Code", "Group ID", "Page Slug"],
    methods: ["PUT"],
    paths: ["/api/v1/groups/[[Group ID]]/pages/[[Page Slug]]"],
    request_kvs: [{
    "body": "[[_includes='[[Embed Code]]']]"
    }],
    parameterized_text: 'Task:  
Embed a YouTube video into the "[[Page]]" page in the "[[Group]]" group, using the following embedding snippet:

<iframe width="560" height="315" src="https://www.youtube.com/embed/m5a4phGJsRY?si=sCq1ix4e4OtMdHUg" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>

then save the changes.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g| (g.wiki_pages.length > 0) && (g.users.include? test_course.logged_in_user) }},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.wiki_pages.length > 0) && (g.users.include? course.logged_in_user)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    page = group.wiki_pages.first

    task.update_initalized_text("Group", group.name)
    task.update_initalized_text("Page", page.title)

    task.update_answer_key("Group ID", group.id)
    task.update_answer_key("Page Slug", page.url)
    task.update_answer_key("Embed Code", 'https://www.youtube.com/embed/m5a4phGJsRY?si=sCq1ix4e4OtMdHUg')
  }

  tasks << task

  task = AgentTask.new({
    id: 'e476f98d-e1e1-4fb7-b8d4-2b0bc832ff69',
    evaluation_parameters: ["Group ID"],
    methods: ["POST"],
    paths: ["/api/v1/groups/[[Group ID]]/memberships/self"],
    request_kvs: [{
      "_method": "DELETE"
      }],
    parameterized_text: 'Task: Leave the group "[[Group]]" in the course "[[Course]]" using the People page in Canvas.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g| (g.users.include? test_course.logged_in_user) }},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (g.users.include? course.logged_in_user)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)

    task.update_answer_key("Group ID", group.id)

  }
  
  tasks << task

  task = AgentTask.new({
    id: 'e5f9684d-4b57-45c7-81e3-0d065f75545b',
    evaluation_parameters: ["User ID"],
    methods: ["PUT"],
    paths: ["/api/v1/users/[[User ID]]/settings"],
    request_kvs: [{
    "manual_mark_as_read": true
    }],
    parameterized_text: 'Task: In your "[[Course]]" course, change your discussion settings so that you must manually mark discussion replies as read.'
  })

  task.populate(test_course) {|course, task|

    task.update_initalized_text("Course", course.course.name)

    task.update_answer_key("User ID", course.logged_in_user.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'f5e1c597-c2ad-45f6-aa7c-7b7dee0d3675',
    evaluation_parameters: ["Group ID"],
    methods: ["POST"],
    paths: ["/api/v1/groups/[[Group ID]]/memberships"],
    request_kvs: [{
    "_method": "POST"}],
    parameterized_text: 'Task: In the course "[[Course]]" view all available groups, and join the self sign-up group named "[[Group]]"'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'group',
    test_course.groups,
    lambda {|groups| groups.select{|g|(!g.users.include? test_course.logged_in_user) }},
    task
  ))

  task.populate(test_course) {|course, task|

    group = course.groups.select{|g| (!AgentTask.groups.include? g) && (!g.users.include? course.logged_in_user)}.first

    if group.nil?
      puts "Cannot find group for task #{task.id}"
      return
    end

    AgentTask.groups << group

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Group", group.name)

    task.update_answer_key("Group ID", group.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'f9e0dc04-ac1e-4189-8c58-91a66d561e06',
    evaluation_parameters: ["Course ID", "Quiz ID", "Last Question Index"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions"],
    request_kvs: [{
    "question_[[Last Question Index]]": "[[ANY]]"}],
    parameterized_text: 'Task: Take the "[[Quiz]]" quiz in the "[[Course]]" course, answer all questions, and submit the quiz.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda{|quizzes| quizzes.select{true}},
    task
  ))

  task.populate(test_course) {|course, task|

    quiz = course.quizzes.select{|q| (!AgentTask.quizzes.include? q)}.first

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    task.update_initalized_text('Course', course.course.name)
    task.update_initalized_text('Quiz', quiz.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Quiz ID", quiz.id)
    task.update_answer_key("Last Question Index", quiz.quiz_questions.last.id) # Verify this... it might actually be the question #? Nope, question id is correct. 

  }

  tasks << task

  task = AgentTask.new({
    id: 'fa70e65c-16fb-4d03-9041-bcf07cf6ae02',
    evaluation_parameters: ["Stream Item ID"],
    methods: ["POST"],
    paths: ["/dashboard/ignore_stream_item/[[Stream Item ID]]"],
    request_kvs: [{
    "_method": "DELETE"
    }],
    parameterized_text: 'Task: In the course "[[Course]]" find the announcement titled "[[Announcement]]" in your Course Activity Stream and remove this notification from your activity stream.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'announcement',
    test_course.announcements,
    lambda {|announcements| announcements.select{true}},
    task
  ))

  task.populate(test_course) {|course, task|

    announcement = course.announcements.select{|a| (!AgentTask.announcements.include? a)}.first

    if announcement.nil?
      puts "Cannot find announcement for task #{task.id}"
      return
    end

    AgentTask.announcements << announcement

    task.update_initalized_text('Course', course.course.name)
    task.update_initalized_text('Announcement', announcement.title)

    stream_item = StreamItem.where(asset_id: announcement.id, asset_type: 'DiscussionTopic').first

    if stream_item.nil?
      puts "Could not find related stream item for task #{task.id}"
      return
    end

    task.update_answer_key("Stream Item ID", stream_item.id )
   

  }

  tasks << task

  task = AgentTask.new({
    type: 'Information Seeking',
    answer_type: 'Date Time',
    parameterized_text: 'Task: In the course "[[Course]]" view all modules, expand the module titled [[Module]]" and identify the due date for the assignment named "[[Assignment]]."'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'module',
    test_course.modules,
    lambda {|_modules| _modules.select{|m| (!m.content_tags.select{|i| i.content_type == 'Assignment'}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    _module = course.modules.select {|m| (!AgentTask.modules.include? m) && (!m.content_tags.select{|i| i.content_type == 'Assignment'}.first.nil?)}.first

    if _module.nil?
      puts "Cannot find module for task #{task.id}"
      return
    end

    AgentTask.modules << _module

    assignment_id = _module.content_tags.select{|t| t.content_type == 'Assignment'}.first.content_id
    assignment = course.assignments.select{|a| a.id == assignment_id}.first


    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Assignment", assignment.title)
    task.update_initalized_text("Module", _module.name)

    task.answer_key = {
      "Date Time": assignment.due_at.strftime("%Y-%m-%d %H:%M")
    }

  }

  tasks << task

  task = AgentTask.new({
    id: 'd098f836-5e11-4e64-ac4c-55dd100ec323',
    evaluation_parameters: ["Course ID", "Assignment ID", "User ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/assignments/[[Assignment ID]]/submissions/[[User ID]]"],
    request_kvs: [{
    "_type": "form data",
    "submission[comment]": ["Thank you for the feedback!"]
    }],
    parameterized_text: 'Task: View your instructor\'s comments on the "[[Quiz]]" quiz in the "[[Course]]" course and add a comment saying "Thank you for the feedback!" to your quiz submission.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda {|quizzes| quizzes.select{|q| (!q.quiz_submissions.select{|qs| (qs.user == test_course.logged_in_user) && (qs.submission.submission_comments.length > 0)}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    quiz = course.quizzes.select{|q| 
    
    if false # set to true for debugging
      puts "Quiz: #{q.title} - #{q.quiz_submissions.length} quiz submissions"

    end

    (!AgentTask.quizzes.include? q) && (!q.quiz_submissions.select{|qs| (qs.user == course.logged_in_user) && (qs.submission.submission_comments.length > 0)}.first.nil?)}.first

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return 
    end
  
    AgentTask.quizzes << quiz

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)

    submission = quiz.quiz_submissions.select{|qs| (qs.user == course.logged_in_user) && (qs.submission.submission_comments.length > 0)}.first

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Assignment ID", quiz.assignment.id)
    task.update_answer_key("User ID", course.logged_in_user.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'fa9d33b1-09e0-43af-996a-74f9acbee197',
    evaluation_parameters: ["Course ID", "Quiz ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/quizzes/[[Quiz ID]]/take"],
    request_kvs: [{}],
    parameterized_text: 'Task: Resume the "[[Quiz]]" in the "[[Course]]" course that you previously started but did not finish.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes, 
    lambda {|quizzes| quizzes.select{|q| (!q.quiz_submissions.select{|qs| (qs.user == test_course.logged_in_user) && (qs.workflow_state == 'untaken')}.first.nil?)}},
    task
  ))

  task.populate(test_course) {|course, task|

    quiz = course.quizzes.select{|q| (!AgentTask.quizzes.include? q) && (!q.quiz_submissions.select{|qs| (qs.user == course.logged_in_user) && (qs.workflow_state == 'untaken')}.first.nil?)}.first

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Quiz ID", quiz.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'f36e03d8-3c1a-4223-ad61-8aca0b4546fb',
    evaluation_parameters: ["Course ID", "Quiz ID"],
    methods: ["POST"],
    paths: ["/courses/[[Course ID]]/quizzes/[[Quiz ID]]/submissions"],
    request_kvs: [{}],
    parameterized_text: 'Task: Submit the "[[Survey]]" survey in the "[[Course]]" course by answering all questions and submitting your responses.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda{|quizzes| quizzes.select{|q| (q.quiz_type == 'survey')}},
    task
  ))

  task.populate(test_course) {|course, task|

    quiz = course.quizzes.select{|q| (!AgentTask.quizzes.include? q) && (q.quiz_type == 'survey')}.first

    if quiz.nil?
      puts "Cannot find survey for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Survey", quiz.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Quiz ID", quiz.id)

  }

  tasks << task

  task = AgentTask.new({
    id: 'fedf3006-7245-4d24-bade-d60bd0e8f6ba',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: View the results of your second attempt on the "[[Quiz]]" in the "[[Course]]" course, and report the time it took in minutes to complete that attempt as displayed in the Last Attempt Details section.'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'quiz',
    test_course.quizzes,
    lambda {|quizzes| quizzes.select{|q| 
      q.reload
      
      (!q.quiz_submissions.select{|qs| (qs.user == test_course.logged_in_user) && (qs.attempt == 2)}.first.nil?)
      }},
      task
  ))

  task.populate(test_course) {|course, task|

    quiz = course.quizzes.select {|q| 
    
    q.reload

    
    (!q.quiz_submissions.select{|qs| 
      if false # set to true for debugging
        puts "qs #{qs}"
        puts "qs attempts: #{qs.attempt}"
        puts "#{qs.inspect}"
      end
    (qs.user == course.logged_in_user) && (qs.attempt == 2)}.first.nil?)}.first

    if quiz.nil?
      puts "Cannot find quiz for task #{task.id}"
      return
    end

    AgentTask.quizzes << quiz

    quiz_submission = quiz.quiz_submissions.select{|qs| (qs.user == course.logged_in_user) && (qs.attempt == 2)}.first
  

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Quiz", quiz.title)

    task.answer_key = {
      "Number": ((quiz_submission.finished_at - quiz_submission.started_at) / 1.minutes).round
    }

  }

  tasks << task

  task = AgentTask.new({
    id: 'b26bef34-a1ce-45c7-9b8a-13651d76d367',
    type: 'Information Seeking',
    answer_type: "Text",
    parameterized_text:'Task: View the feedback you received from [[User]] for the "[[Discussion]]" peer-reviewed discussion by accessing the Feedback tray from the Course Grades page in your "[[Course]]" course. What was the comment that [[User]] left for your submission?'
  })

  resource_manifest.add_resource_request(ResourceRequest.new(
    'discussion',
    test_course.discussions,
    lambda {|discussions| discussions.select{|d| 
      (!d.assignment.nil?) && 
      (!d.assignment.submissions.select{|s| (s.user == test_course.logged_in_user) && (s.submission_comments.length > 0)}.first.nil?)
    }},
    task
  ))

  task.populate(test_course){|course, task|

    discussion = course.discussions.select{|d| (!AgentTask.discussions.include? d) && (!d.assignment.nil?) && (!d.assignment.submissions.select{|s| (s.user == course.logged_in_user) && (s.submission_comments.length > 0)}.first.nil?)}.first

    if discussion.nil?
      puts "Cannot find discussion for task #{task.id}"
      return
    end

    submission = discussion.assignment.submissions.select{|s| s.user === course.logged_in_user}.first

    comment = submission.submission_comments.select{|c| c.author != course.teacher}.first


    AgentTask.discussions << discussion

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Discussion", discussion.title)
    task.update_initalized_text("User", comment.author.name)

    task.answer_key = {
      "Text": comment.comment
    }

  }

  tasks << task

  task = AgentTask.new({
    id: 'd8f5a7b0-64e5-4c07-aff4-44d0e26f2eb2',
    type: 'Information Seeking',
    answer_type: 'Numeric',
    parameterized_text: 'Task: In the course "[[Course]]" view your Learning Mastery grades for the outcome group "[[Course]]" expand the group to see all outcomes, and report the number of mastered outcomes.'
  })

  task.populate(test_course) {|course, task|

    task.update_initalized_text("Course", course.course.name)

    task.answer_key = {
      "Number": 0
    }

  }

  tasks << task

  task = AgentTask.new({
    id: 'ff0f349b-4812-41ae-8b85-ae6c2899db2c',
    evaluation_parameters: ["Course ID", "Item ID", "Module ID", "Assignment Set ID"],
    methods: ["GET","POST"],
    paths: ["/courses/[[Course ID]]/modules/items/[[Item ID]]/choose","/api/v1/courses/[[Course ID]]/modules/[[Module ID]]/items/[[Item ID]]/select_mastery_path"],
    request_kvs: [{},{
    "assignment_set_id": "[[Assignment Set ID]]"
    }],
    parameterized_text: 'Task: In the "[[Course]]" course, navigate to the "[[Module]]" module, click the "Choose Assignment Group" link, and select the assignment titled "[[Assignment]]" by clicking the Select button.'
  })

  task.populate(test_course){|course, task|

    m = course.course.context_modules.create!({name: 'Special Module A', workflow_state: 'active'})
    
    assignment_with_grade = course.assignments.select{|a| !a.submissions.select{|s| (s.user == course.logged_in_user) && (s.graded?)}.first.nil?}.first

    if assignment_with_grade.nil?
      puts "Cannot find assignment with logged in user grade for task #{task.id}"
      return
    end

    assignment_option_1 = course.assignments.select{|a| a != assignment_with_grade }.first

    if assignment_option_1.nil?
      puts "Cannot find assignment option 1 for task #{task.id}"
      return
    end

    assignment_option_2 = course.assignments.select{|a| (a != assignment_with_grade) && (a != assignment_option_1)}.first

    if assignment_option_2.nil?
      puts "Cannot find assignment option 2 for task #{task.id}"
      return 
    end

    tag = m.add_item(id: assignment_with_grade.id, type: "assignment")
    # m.add_item(id: assignment_option_1.id, type: "assignment")
    # m.add_item(id: assignment_option_2.id, type: "assignment")

    assignment_set_1 = ConditionalRelease::AssignmentSet.new(
            assignment_set_associations: [
              ConditionalRelease::AssignmentSetAssociation.new(assignment_id: assignment_option_1.id)
            ]
          )
    
    assignment_set_2 = ConditionalRelease::AssignmentSet.new(
            assignment_set_associations: [
              ConditionalRelease::AssignmentSetAssociation.new(assignment_id: assignment_option_2.id)
            ]
          )

    ranges = [
      ConditionalRelease::ScoringRange.new(
        lower_bound:0.0,
        upper_bound:1.0,
        assignment_sets: [ assignment_set_1, assignment_set_2 ]
      )
    ]

    rule = course.course.conditional_release_rules.create!(trigger_assignment: assignment_with_grade, scoring_ranges: ranges)

    m.reload
    course.course.reload

    selected_option = [assignment_option_1, assignment_option_2].sample

    task.update_initalized_text("Course", course.course.name)
    task.update_initalized_text("Module", m.name)
    task.update_initalized_text("Assignment", selected_option.title)

    task.update_answer_key("Course ID", course.course.id)
    task.update_answer_key("Item ID", tag.id)
    task.update_answer_key("Module ID", m.id)

    if selected_option == assignment_option_1 
      task.update_answer_key("Assignment Set ID", assignment_set_1.id)
    else
      task.update_answer_key("Assignment Set ID", assignment_set_2.id)
    end

  }

  tasks << task

  puts "last task"
  puts task.to_hash

  puts "#{tasks.length} tasks defined!"

  # resource_manifest.compute_task_populate_order(tasks)
  resource_manifest.print_resource_requests()
  # resource_manifest.find_valid_order()
  #resource_manifest.populate_tasks(tasks)

  resource_manifest.populate_tasks_v2(tasks)

  return tasks

  

end

def get_course_stats(course)
    # Compute some course stats to assess how much of each resource there is.
    # This is for debugging purposes.
    stats = [
      ['assignment', course.assignments.length],
      ['group', course.groups.length],
      ['quiz', course.quizzes.length],
      ['page', course.pages.length],
      ['discussion', course.discussions.length],
      ['announcement', course.announcements.length],
      ['module', course.modules.length]
  ]

    stats = stats.sort{|a,b| a[1] <=> b[1]}
    stats

    puts "#{course.course.name} Course stats:"
    puts stats
end


=begin
Run with:
docker-compose run --remove-orphans web bundle exec rails runner spec/fixtures/data_generation/custom_data.rb
=end

#explore
test_courses = generate_test_environment
all_tasks = []

test_courses.each{|test_course|
  get_course_stats(test_course)
}

test_courses.each{|test_course|
  task_instances = create_task_instances(test_course)

  if task_instances
    all_tasks += task_instances
  else
    puts task_instances
  end

  # Enroll all main users in all other courses to populate the dashboard nicely with course cards for each of them.
  test_courses.select{|c| c != test_course }.each{|other_course| 
    puts "Enrolling #{test_course.logged_in_user.name} in #{other_course.course.name}"
    other_course.enroll_student(test_course.logged_in_user)}
}

task_objects = []
  
all_tasks.each {|t| 
  #puts "Task: #{t.id}\n#{t.instance_text}"
  task_objects << t.to_hash
}

task_instances = aggregate_task_objects(task_objects)
puts "generated #{task_instances.length} task instances"

# output the instances to yaml/json format.
File.open('tasks.json', 'w') {|json_file| json_file.write task_instances.to_json}
File.open('tasks.yaml', "w") {|yaml_file| yaml_file.write task_instances.to_yaml}

#puts Account.default.settings.pretty_inspect