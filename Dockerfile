# Use AWS Lambda Python 3.12 base image
FROM public.ecr.aws/lambda/python:3.12

# Install git (required to install acido from GitHub)
RUN dnf install -y git && dnf clean all

# Copy requirements and install Python dependencies
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

# Copy VERSION file
COPY VERSION ${LAMBDA_TASK_ROOT}/

# Copy the entire acido package
COPY . ${LAMBDA_TASK_ROOT}/

# Set the Lambda handler for secrets sharing
CMD ["lambda_handler.lambda_handler"]
